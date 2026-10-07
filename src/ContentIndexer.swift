import Foundation

/// Filesystem walk for **content search** mode. It is deliberately separate
/// from `FileIndexer` so content search never slows down (or allocates for)
/// plain file search.
///
/// For every regular file it attaches the text contents when the file is
/// within the size limit and looks like text; otherwise it leaves the contents
/// empty:
///   - files larger than `maxFileSize` (default 20 MiB; 0 means no limit) are
///     never read, and
///   - binary files are never content-searched (detected from the contents:
///     NUL bytes, invalid UTF-8, or many control characters — even when the
///     extension looks like text).
///
/// Neither is removed from the list: "skipping" only skips their *contents*, so
/// they still match by name/path (see `FuzzyMatcher.matchContent`).
enum ContentIndexer {

    /// Bytes inspected to decide whether a file is binary.
    static let probeBytes = 8 * 1024

    static func enumerate(
        paths: [String],
        typeFilter: TypeFilter,
        namePattern: String?,
        includeHidden: Bool,
        maxFileSize: Int,
        onBatch: @escaping @MainActor ([SearchableItem]) -> Void,
        onComplete: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey,
                .fileSizeKey
            ]
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !includeHidden {
                options.insert(.skipsHiddenFiles)
            }

            let loweredName = namePattern?.lowercased()
            var batch: [SearchableItem] = []
            batch.reserveCapacity(128)

            for path in paths {
                let url = URL(fileURLWithPath: path)
                guard let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(keys),
                    options: options
                ) else { continue }

                while let fileURL = enumerator.nextObject() as? URL {
                    guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }

                    let isDir = values.isDirectory ?? false
                    let isSymlink = values.isSymbolicLink ?? false

                    // Avoid symlink loops while still allowing symlinked files.
                    if isDir && isSymlink { continue }
                    // Only regular files have contents to search.
                    if isDir { continue }
                    if values.isRegularFile == false { continue }

                    if let loweredName {
                        let name = fileURL.lastPathComponent.lowercased()
                        if !name.contains(loweredName) { continue }
                    }

                    if !typeFilter.matches(url: fileURL,
                                            ext: fileURL.pathExtension,
                                            isDirectory: false) {
                        continue
                    }

                    // "Skipping" only means skipping the raw *contents*: files
                    // are still listed so they can match by name/path.
                    let ext = fileURL.pathExtension
                    let category = FileTypeRegistry.category(for: ext)
                    let content: String?
                    if category == .audio {
                        // Only audio metadata is searchable (title / artist /
                        // album); video and images are name-only.
                        content = MediaMetadata.searchableText(for: fileURL, category: category)
                    } else if maxFileSize > 0, (values.fileSize ?? 0) > maxFileSize {
                        content = nil
                    } else if FileTypeRegistry.isLikelyBinary(ext: ext) {
                        content = nil
                    } else {
                        let readLimit = maxFileSize > 0 ? maxFileSize : Int.max
                        content = readTextContent(url: fileURL, maxBytes: readLimit)
                    }

                    batch.append(SearchableItem(url: fileURL, isDirectory: false, content: content))

                    if batch.count >= 128 {
                        let chunk = batch
                        batch.removeAll(keepingCapacity: true)
                        DispatchQueue.main.async {
                            onBatch(chunk)
                        }
                    }
                }
            }

            if !batch.isEmpty {
                let chunk = batch
                DispatchQueue.main.async {
                    onBatch(chunk)
                }
            }

            DispatchQueue.main.async {
                onComplete()
            }
        }
    }

    /// Reads up to `maxBytes` and returns the decoded text, or nil if the file
    /// looks binary. The returned string is not lowercased; matching does
    /// case-insensitive substring lookup so only one copy is kept in memory.
    static func readTextContent(url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Probe first so a binary file is rejected before reading it in full.
        let probeLimit = maxBytes >= Int.max ? probeBytes : min(probeBytes, maxBytes)
        let probe = (try? handle.read(upToCount: probeLimit)) ?? Data()
        if probe.isEmpty { return "" }
        if looksBinary(probe) { return nil }

        var data = probe
        if probe.count < maxBytes {
            let rest: Data?
            if maxBytes >= Int.max {
                rest = try? handle.readToEnd()
            } else {
                rest = try? handle.read(upToCount: maxBytes - probe.count)
            }
            if let rest, !rest.isEmpty { data.append(rest) }
        }

        // `decoding:` never fails: a trailing partial multibyte character at the
        // read cap is replaced instead of discarding the whole file.
        return String(decoding: data, as: UTF8.self)
    }

    /// Content-based binary heuristic, applied to every file that reaches this
    /// point (including ones with a text extension): NUL bytes, invalid UTF-8,
    /// or too many control characters (ignoring tab / newline) mean binary, so
    /// the file's contents are never searched (it can still match by name).
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
        // A single replacement character can just be a multibyte character cut
        // at the probe boundary; two or more mean genuinely invalid UTF-8.
        if invalid >= 2 { return true }
        return total > 0 && control >= 2 && control * 100 / total > 10
    }
}
