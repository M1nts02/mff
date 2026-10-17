import Foundation

// MARK: - On-disk filename index

/// Per-entry binary-file content text (currently audio metadata; nil
/// otherwise). Stored
/// as one haystack (title + artist + album joined) so content mode can match
/// without re-reading the file.
struct IndexedBinary {
    var text: String?
}

/// A flat, mmap-friendly filename index: one contiguous UTF-8 blob of
/// NUL-separated paths, a parallel flag byte per entry (is-directory /
/// is-binary), and a second blob holding binary-file content. Loading is a
/// mmap — no per-entry allocation and no deserialization, so a query never
/// touches the filesystem or allocates for the corpus.
///
/// Layout (little-endian), written by `save(to:)`:
///   magic    : 8 bytes  "MFFIDX\0\0" (version-neutral; see `version` below)
///   count    : UInt32   number of entries
///   version  : UInt32   `formatVersion` (bumped on any layout or meaning change; a
///                       mismatch makes `load` return nil so the daemon rebuilds)
///   offsets  : (count + 1) × UInt32   byte offsets into `pathBlob` for entry i
///   mOffsets : (count + 1) × UInt32   byte offsets into `binaryBlob` for entry i
///   flags    : count bytes  bit0 = isDirectory, bit1 = isBinary
///   pathBlob : UTF-8 paths, entry i spans offsets[i]..<offsets[i+1]
///   binaryBlob : binary-file content text spanning binaryOffsets[i]..<binaryOffsets[i+1]
final class FileIndex {
    /// On-disk format version. Bump this whenever the layout or the meaning of
    /// the stored data changes, so an upgraded binary discards and rebuilds an
    /// index written by an older version instead of misreading it.
    static let formatVersion: UInt32 = 11
    /// Constant across format versions: the header `version` field alone decides
    /// whether a file is readable, so a layout bump is a one-line change.
    private static let magic = "MFFIDX\0\0"
    private let pathBlob: Data
    private let binaryBlob: Data
    private let offsets: [UInt32]
    private let binaryOffsets: [UInt32]
    private let flags: [UInt8]

    var count: Int { offsets.count - 1 }

    /// Roots the index was built from (for diagnostics / matching logic).
    let roots: [String]
    let builtAt: Date

    init(pathBlob: Data, binaryBlob: Data, offsets: [UInt32], binaryOffsets: [UInt32],
         flags: [UInt8], roots: [String], builtAt: Date) {
        self.pathBlob = pathBlob
        self.binaryBlob = binaryBlob
        self.offsets = offsets
        self.binaryOffsets = binaryOffsets
        self.flags = flags
        self.roots = roots
        self.builtAt = builtAt
        // Build the path -> index map up front so concurrent daemon searches
        // never race on a lazy initializer.
        var map = [String: Int](minimumCapacity: offsets.count)
        let base = pathBlob.startIndex
        for i in 0..<(offsets.count - 1) {
            let s = base + Int(offsets[i])
            let e = base + Int(offsets[i + 1])
            map[String(decoding: pathBlob[s..<e], as: UTF8.self)] = i
        }
        self.lookup = map
    }

    /// The path of entry `i`.
    func path(at i: Int) -> String {
        // The blobs may be slices with a non-zero `startIndex` (loaded from
        // disk), so offset by it rather than assuming a zero base.
        let base = pathBlob.startIndex
        let start = base + Int(offsets[i])
        let end = base + Int(offsets[i + 1])
        return String(decoding: pathBlob[start..<end], as: UTF8.self)
    }

    func isDirectory(at i: Int) -> Bool {
        flags[i] & 1 != 0
    }

    /// Whether the file was detected as binary at index time (only meaningful
    /// for regular files; directories are never "binary").
    func isBinary(at i: Int) -> Bool {
        flags[i] & 2 != 0
    }

    /// Binary-file content text for entry `i`, if it was parsed at index time
    /// (currently audio metadata; later video / image / PDF).
    func binaryContent(at i: Int) -> IndexedBinary {
        let base = binaryBlob.startIndex
        let start = base + Int(binaryOffsets[i])
        let end = base + Int(binaryOffsets[i + 1])
        guard end > start else { return IndexedBinary() }
        // One NUL-terminated field: the joined title/artist/album text.
        let slice = binaryBlob[start..<end]
        let text = slice.last == 0 ? String(decoding: slice.dropLast(), as: UTF8.self)
                                   : String(decoding: slice, as: UTF8.self)
        return IndexedBinary(text: text.isEmpty ? nil : text)
    }

    /// Entry index for a path, if present (paths are stored in insertion order).
    /// Built once at construction (not lazily) so concurrent searches on the
    /// daemon never race on first access.
    private let lookup: [String: Int]

    func index(of path: String) -> Int? { lookup[path] }

    func contains(_ path: String) -> Bool { lookup[path] != nil }

    // MARK: - Building

    /// Walks `roots` and returns an in-memory index. Symlink loops are avoided
    /// and package descendants are skipped, matching `FileIndexer`. For each
    /// regular file the header is probed to record an is-binary flag, and audio
    /// files have their title/artist/album parsed and stored.
    ///
    /// `onProgress` (if given) is called periodically with the number of entries
    /// added so far and the directory currently being scanned, so a long build
    /// can report progress.
    ///
    /// Enumeration uses `readdir` (FastDir) rather than `FileManager.enumerator`
    /// so a slow external volume is not stat-ed once per entry.
    /// Whether a file's header must be probed to decide is-binary. Known
    /// binary/media categories don't need it; text/unknown/archive do.
    private static func needsBinaryProbe(category: FileCategory) -> Bool {
        switch category {
        case .audio, .image, .video: return false        // always binary
        case .document: return false                     // pdf/office are binary
        case .archive: return false                      // archives are binary
        case .app, .folder: return false                 // directories
        case .text, .other: return true                  // text vs binary unclear
        }
    }

    static func build(roots: [String], exclude: [String], includeHidden: Bool,
                      onProgress: ((_ count: Int, _ current: String) -> Void)? = nil) -> FileIndex {
        let matcher = exclude.isEmpty ? nil : ExcludeMatcher(patterns: exclude)

        // Pass 1: enumerate (readdir — cheap even on slow disks).
        var entries: [(path: String, isDir: Bool)] = []
        entries.reserveCapacity(4096)
        for root in roots {
            FastDir.walk(root: root, includeHidden: includeHidden,
                         exclude: matcher.map { m in { m.matches($0) } }) { path, isDir, _ in
                entries.append((path, isDir))
            }
        }

        // Pass 2: per-file work (header probe + media metadata) runs on a small
        // thread pool. This I/O is the dominant cost on external disks, and it
        // parallelizes well (multiple files in flight).
        var flags = [UInt8](repeating: 0, count: entries.count)
        var binaryTexts = [String?](repeating: nil, count: entries.count)
        let lock = NSLock()
        var next = 0
        var done = 0
        var lastReport = Date.distantPast
        // Slow external disks thrash with many concurrent readers; keep it low.
        let workers = IndexBuildConcurrency.value()

        func work() {
            while true {
                let i: Int
                lock.lock()
                i = next
                next += 1
                lock.unlock()
                if i >= entries.count { return }
                let path = entries[i].path
                let isDir = entries[i].isDir
                var flag: UInt8 = isDir ? 1 : 0
                var text: String?
                if !isDir {
                    let url = URL(fileURLWithPath: path)
                    let ext = url.pathExtension
                    let category = FileTypeRegistry.category(for: ext)
                    let isBinary = Self.needsBinaryProbe(category: category)
                        ? FileProbe.isBinary(url: url) : true
                    if isBinary { flag |= 2 }
                    if MediaMetadata.hasExtractableMetadata(ext: ext) {
                        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        text = MediaMetadata.searchableText(for: url, category: category, fileSize: size)
                    }
                }

                lock.lock()
                flags[i] = flag
                binaryTexts[i] = text
                done += 1
                let report = onProgress.map { cb -> Bool in
                    guard Date().timeIntervalSince(lastReport) > 0.25 else { return false }
                    lastReport = Date()
                    cb(done, (path as NSString).deletingLastPathComponent)
                    return true
                } ?? false
                _ = report
                lock.unlock()
            }
        }

        DispatchQueue.concurrentPerform(iterations: workers) { _ in work() }

        // Pass 3: assemble the flat blobs in enumeration order.
        var pathBlob = Data()
        var binaryBlob = Data()
        var offsets: [UInt32] = [0]
        var binaryOffsets: [UInt32] = [0]
        for (i, e) in entries.enumerated() {
            let bytes = Array(e.path.utf8)
            if pathBlob.count + bytes.count < Int(UInt32.max),
               binaryBlob.count < Int(UInt32.max) {
                pathBlob.append(contentsOf: bytes)
                offsets.append(UInt32(pathBlob.count))
                if let t = binaryTexts[i], !t.isEmpty {
                    // The wire protocol is line-oriented, so fold newlines out.
                    let flat = t.replacingOccurrences(of: "\n", with: " ")
                    binaryBlob.append(contentsOf: Array(flat.utf8))
                }
                binaryBlob.append(0)
                binaryOffsets.append(UInt32(binaryBlob.count))
            }
        }
        let finalFlags = Array(flags.prefix(offsets.count - 1))

        return FileIndex(pathBlob: pathBlob, binaryBlob: binaryBlob, offsets: offsets,
                         binaryOffsets: binaryOffsets, flags: finalFlags,
                         roots: roots, builtAt: Date())
    }

    // MARK: - Persistence

    func save(to url: URL) throws {
        var data = Data()
        data.append(contentsOf: Array(Self.magic.utf8))
        appendU32(&data, UInt32(offsets.count - 1))   // count
        appendU32(&data, Self.formatVersion)          // format version
        for off in offsets { appendU32(&data, off) }
        for off in binaryOffsets { appendU32(&data, off) }
        data.append(contentsOf: flags)
        // Align each blob to 8 bytes for a clean mmap.
        while data.count % 8 != 0 { data.append(0) }
        data.append(pathBlob)
        while data.count % 8 != 0 { data.append(0) }
        data.append(binaryBlob)

        try data.write(to: url, options: .atomic)

        let meta: [String: Any] = [
            "roots": roots,
            "builtAt": builtAt.timeIntervalSince1970,
            "count": Int(offsets.count - 1)
        ]
        if let metaData = try? JSONSerialization.data(withJSONObject: meta) {
            try? metaData.write(to: url.appendingPathExtension("meta"))
        }
    }

    /// Appends a UInt32 little-endian (avoiding `withUnsafeBytes` on loop
    /// variables, which trips the Swift ownership checker in some versions).
    private func appendU32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    /// Loads via mmap. Returns nil if the file is missing, malformed, or written
    /// by a different `formatVersion` (in which case the daemon rebuilds).
    static func load(from url: URL) -> FileIndex? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard data.count >= 16 else { return nil }
        let magic = data.prefix(8)
        guard magic == Data(Self.magic.utf8) else {
            // A different magic means an older/newer on-disk layout; treat as
            // unloadable so the caller rebuilds.
            return nil
        }

        func readU32(_ offset: Int) -> UInt32 {
            UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }

        let count = Int(readU32(8))
        // Reject an index written by a different format version.
        guard readU32(12) == Self.formatVersion else { return nil }
        var cursor = 16
        // offsets + binaryOffsets + flags
        guard data.count >= cursor + (count + 1) * 4 * 2 + count else { return nil }
        var offsets = [UInt32](repeating: 0, count: count + 1)
        for i in 0...(count) {
            offsets[i] = readU32(cursor)
            cursor += 4
        }
        var binaryOffsets = [UInt32](repeating: 0, count: count + 1)
        for i in 0...(count) {
            binaryOffsets[i] = readU32(cursor)
            cursor += 4
        }
        var flags = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            flags[i] = data[cursor]
            cursor += 1
        }
        while cursor % 8 != 0 { cursor += 1 }
        guard data.count >= cursor else { return nil }
        let pathBlob = data[cursor...]
        let pathLen = Int(offsets[count])
        var metaStart = cursor + pathLen
        while metaStart % 8 != 0 { metaStart += 1 }
        guard data.count >= metaStart else { return nil }
        let binaryBlob = data[metaStart...]

        // Roots / builtAt from the sidecar metadata (best effort).
        var roots: [String] = []
        var builtAt = Date()
        if let metaData = try? Data(contentsOf: url.appendingPathExtension("meta")),
           let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
            roots = meta["roots"] as? [String] ?? []
            if let ts = meta["builtAt"] as? Double { builtAt = Date(timeIntervalSince1970: ts) }
        }

        return FileIndex(pathBlob: pathBlob, binaryBlob: binaryBlob, offsets: offsets,
                         binaryOffsets: binaryOffsets, flags: flags, roots: roots, builtAt: builtAt)
    }
}

// MARK: - Binary probe

/// Classifies a file as binary by reading a small header, so the index can
/// record it without storing contents. A `.md` that is actually an md emulator
/// binary (or any mislabeled file) is thus flagged binary at index time.
enum IndexBuildConcurrency {
    /// Concurrency for the per-file I/O pass. Override with MFF_INDEX_WORKERS
    /// (used for tuning on slow external disks).
    static func value() -> Int {
        if let s = ProcessInfo.processInfo.environment["MFF_INDEX_WORKERS"], let n = Int(s) { return max(1, n) }
        // ~4 concurrent readers is the sweet spot on slow external disks;
        // more just thrashes the disk.
        return min(4, max(2, ProcessInfo.processInfo.activeProcessorCount))
    }
}

enum FileProbe {
    static let probeBytes = 8192

    static func isBinary(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: probeBytes)) ?? Data()
        return looksBinary(data)
    }

    /// Same heuristic `ContentIndexer.looksBinary` uses: NUL bytes, invalid
    /// UTF-8, or a high proportion of control characters.
    static func looksBinary(_ data: Data) -> Bool {
        if data.isEmpty { return false }
        if data.contains(0) { return true }

        let text = String(decoding: data, as: UTF8.self)
        var invalid = 0
        var control = 0
        var total = 0
        for scalar in text.unicodeScalars {
            total += 1
            let value = scalar.value
            if value == 0xFFFD {
                invalid += 1
            } else if (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D)
                        || value == 0x7F {
                control += 1
            }
        }
        if invalid >= 2 { return true }
        return total > 0 && control >= 2 && control * 100 / total > 10
    }
}

// MARK: - Glob-ish exclude matcher

/// Matches the `[index] exclude` patterns. Supports `**/name`, `**/name/**`,
/// `*.ext`, and plain substring/prefix forms, which covers the common cases
/// (`node_modules`, `DerivedData`, caches) without a full glob engine.
struct ExcludeMatcher {
    private let patterns: [String]

    init(patterns: [String]) {
        // Expand `~` / `${HOME}` / `$HOME` so `~/Library/...` style excludes work
        // from both config.toml and --exclude.
        self.patterns = patterns.map { PathExpansion.expand($0) }
    }

    func matches(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        for pattern in patterns {
            if matchPattern(pattern, path: path, name: name) { return true }
        }
        return false
    }

    private func matchPattern(_ pattern: String, path: String, name: String) -> Bool {
        var pat = pattern
        // `**/node_modules` and `**/node_modules/**` both reduce to "a path
        // component named node_modules".
        if pat.hasPrefix("**/") { pat = String(pat.dropFirst(3)) }
        if pat.hasSuffix("/**") { pat = String(pat.dropLast(3)) }
        if pat.hasSuffix("/") { pat = String(pat.dropLast()) }

        if pat.contains("/") {
            // A multi-component pattern: match the path suffix or substring.
            return path == pat || path.hasSuffix("/" + pat) || path.contains("/" + pat + "/")
        }
        if pat.hasPrefix("*.") {
            return name.hasSuffix(String(pat.dropFirst(1)))
        }
        if pat.hasPrefix("*") {
            return name.hasSuffix(String(pat.dropFirst()))
        }
        return name == pat || path.contains("/" + pat + "/") || path.hasSuffix("/" + pat)
    }
}
