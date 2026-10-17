import Foundation

// MARK: - Index client (GUI / CLI side)

/// Talks to the index daemon over its Unix socket. Used by a plain `mff` run to
/// (a) detect whether a daemon is available and (b) fetch candidate paths for a
/// query. Every call fails soft: if the socket is missing or the daemon is
/// unreachable the caller falls back to a live filesystem walk.
struct IndexClient {
    let socketPath: String

    init(socketPath: String = IndexPaths.socketPath()) {
        self.socketPath = socketPath
    }

    /// A `PING` reply.
    struct Ping {
        let pid: Int
        /// "ready" | "partial" | "empty"
        let state: String
        let count: Int
    }

    /// True if a daemon is listening and answers PING.
    func probe() -> Ping? {
        guard let fd = connect() else { return nil }
        defer { close(fd) }
        guard send(fd, "PING\n") else { return nil }
        let reader = LineReader(fd: fd)
        guard let line = reader.next(), line.hasPrefix("PONG ") else { return nil }
        // PONG <pid> <state> <volumeCount> <entries>
        let parts = line.split(separator: " ")
        guard parts.count >= 5, let pid = Int(parts[1]), Int(parts[3]) != nil,
              let count = Int(parts[4]) else { return nil }
        return Ping(pid: pid, state: String(parts[2]), count: count)
    }

    /// Per-volume report (ROOTS).
    struct VolumeReport { let id: String; let path: String; let state: String; let entries: Int }

    func volumes() -> [VolumeReport] {
        guard let fd = connect() else { return [] }
        defer { close(fd) }
        guard send(fd, "ROOTS\n") else { return [] }
        var out: [VolumeReport] = []
        let reader = LineReader(fd: fd)
        while let line = reader.next() {
            if line == "END" { break }
            guard line.hasPrefix("VOL ") else { continue }
            let p = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
            guard p.count == 5, let entries = Int(p[4]) else { continue }
            out.append(VolumeReport(id: String(p[1]), path: String(p[2]),
                                    state: String(p[3]), entries: entries))
        }
        return out
    }

    /// A candidate from the daemon: its path, plus (content mode only) the
    /// indexed binary content as a lowercased searchable string, and whether the
    /// file was classified binary at index time.
    struct Hit {
        let path: String
        let binaryText: String?
        let isBinary: Bool
        /// From the index (no `stat`); false for `HIT` lines from an older
        /// daemon that did not send the kind field.
        let isDirectory: Bool

        /// Last path component, without building a `URL`.
        var name: String {
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        }

        /// Lowercased extension without the dot ("" if none).
        var fileExtension: String {
            (name as NSString).pathExtension.lowercased()
        }
    }

    /// Streams candidate hits for `query`, restricted to any of `prefixes`
    /// (subtrees; empty = the whole index). `content` also matches indexed audio
    /// metadata. Returns them in batches as they arrive; `onComplete` gets the
    /// total. Returns false if not connected.
    @discardableResult
    func search(query: String,
                prefixes: [String] = [],
                excludes: [String] = [],
                content: Bool = false,
                onBatch: @escaping ([Hit]) -> Void,
                onComplete: @escaping (_ total: Int, _ partial: Bool) -> Void) -> Bool {
        guard let fd = connect() else { return false }
        // Strip newlines: the protocol is line-oriented. Prefixes and excludes
        // are each joined with ";"; the query (which may contain spaces) follows
        // a Tab, and the three head fields are space-separated.
        let safe = query.replacingOccurrences(of: "\n", with: " ")
        let safePrefix = prefixes.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: ";")
        let safeExclude = excludes.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: ";")
        let mode = content ? "content" : "name"
        guard send(fd, "SEARCH \(mode) \(safePrefix) \(safeExclude)\t\(safe)\n") else { close(fd); return false }

        var batch: [Hit] = []
        batch.reserveCapacity(256)
        var total = 0
        var partial = false
        let reader = LineReader(fd: fd)
        while let line = reader.next() {
            if line.hasPrefix("HIT ") {
                // "HIT <path>\tD|F".
                let body = line.dropFirst(4)
                let tab = body.firstIndex(of: "\t")
                batch.append(Hit(path: tab.map { String(body[..<$0]) } ?? String(body),
                                 binaryText: nil, isBinary: false,
                                 isDirectory: body.last == "D"))
                if batch.count >= 256 {
                    let chunk = batch
                    batch.removeAll(keepingCapacity: true)
                    onBatch(chunk)
                }
            } else if line.hasPrefix("BIN ") {
                // "BIN <path>\tF".
                let body = line.dropFirst(4)
                let tab = body.firstIndex(of: "\t")
                batch.append(Hit(path: tab.map { String(body[..<$0]) } ?? String(body),
                                 binaryText: nil, isBinary: true, isDirectory: false))
                if batch.count >= 256 {
                    let chunk = batch
                    batch.removeAll(keepingCapacity: true)
                    onBatch(chunk)
                }
            } else if line.hasPrefix("BCONTENT ") {
                // BCONTENT <path>\t<metadata text>
                let body = line.dropFirst("BCONTENT ".count)
                let tab = body.firstIndex(of: "\t")
                let path = tab.map { String(body[..<$0]) } ?? String(body)
                let text = tab.map { String(body[body.index(after: $0)...]) } ?? ""
                let binaryText = text.isEmpty ? nil : text.lowercased()
                batch.append(Hit(path: path, binaryText: binaryText, isBinary: false,
                                 isDirectory: false))
                if batch.count >= 256 {
                    let chunk = batch
                    batch.removeAll(keepingCapacity: true)
                    onBatch(chunk)
                }
            } else if line.hasPrefix("END") {
                if !batch.isEmpty { onBatch(batch); batch.removeAll(keepingCapacity: true) }
                // END <matched> <partial:0|1>
                let p = line.split(separator: " ")
                total = p.count > 1 ? (Int(p[1]) ?? 0) : 0
                partial = p.count > 2 && p[2] == "1"
                break
            } else if line.hasPrefix("ERR") {
                break
            }
        }
        if !batch.isEmpty { onBatch(batch) }
        close(fd)
        onComplete(total, partial)
        return true
    }

    // MARK: socket plumbing

    private func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                path.withCString { src in
                    strcpy(dst, src)
                }
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }

    private func send(_ fd: Int32, _ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard !bytes.isEmpty else { return true }
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                return Darwin.write(fd, base, buf.count)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    /// Reads one `\n`-terminated line (buffered reads per call are fine here as
    /// responses are small; a persistent reader would need state across calls).
    /// Buffered line reader. Reading one byte at a time cost a syscall per
    /// character, which dominated large responses.
    private final class LineReader {
        private let fd: Int32
        private var buffer = [UInt8]()
        private var cursor = 0
        private let chunkSize = 64 * 1024

        init(fd: Int32) { self.fd = fd }

        func next() -> String? {
            while true {
                if let nl = buffer[cursor...].firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[cursor..<nl], as: UTF8.self)
                    cursor = nl + 1
                    // Reclaim consumed space occasionally.
                    if cursor > chunkSize {
                        buffer.removeFirst(cursor)
                        cursor = 0
                    }
                    return line
                }
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 {
                    if cursor < buffer.count {
                        let tail = String(decoding: buffer[cursor...], as: UTF8.self)
                        buffer.removeAll(); cursor = 0
                        return tail.isEmpty ? nil : tail
                    }
                    return nil
                }
                if cursor > 0 {
                    buffer.removeFirst(cursor)
                    cursor = 0
                }
                buffer.append(contentsOf: chunk[0..<n])
            }
        }
    }
}
