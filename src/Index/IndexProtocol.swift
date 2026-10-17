import Foundation

// MARK: - Index daemon wire protocol

/// mff and its index daemon talk over a Unix domain socket with a tiny
/// line-oriented protocol. Lines are UTF-8 and terminated by `\n`.
///
///   -> PING
///   <- PONG <pid> <state> <volumes> <entries>
///   -> ROOTS
///   <- VOL <id> <path> <state> <entries>   (one per volume, then END)
///   -> SEARCH <mode> <prefixes ';'> <excludes ';'>\t<query>   (mode = name | content)
///   <- HIT <path>\tD|F           (one per match; tab + kind: D dir, F file)
///   <- BIN <path>\tF             (content mode: file classified binary)
///   <- BCONTENT <path>\t<text>   (content mode: indexed binary-file content)
///   <- END <matched> <partial 0|1>   (terminates the response)
///   <- ERR <message>
///
/// Paths containing a newline (vanishingly rare) are skipped by the daemon so
/// one path is always exactly one line.
enum IndexPaths {
    /// Index files live under Application Support; the config file stays in
    /// `~/.config` (kept separate on purpose).
    static func directory() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first?.path
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support")
        return base + "/mff/index"
    }

    static func manifestFile() -> String { directory() + "/manifest.json" }
    static func socketPath() -> String { directory() + "/mffd.sock" }
    static func lockPath() -> String { directory() + "/mffd.lock" }
    /// Base index for one volume (mmap).
    static func shardFile(id: String) -> String { directory() + "/vol-" + safe(id) + ".idx" }
    /// Incremental overlay for one volume.
    static func overlayFile(id: String) -> String { directory() + "/vol-" + safe(id) + ".ovl" }
    /// FS-safe form of a volume id (UUIDs contain dashes; path ids contain "/").
    private static func safe(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
    }

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(atPath: directory(),
                                                 withIntermediateDirectories: true)
    }
}
