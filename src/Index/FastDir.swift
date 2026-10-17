import Foundation

// MARK: - Bulk directory reader (readdir)

/// A directory entry returned by `FastDir`.
struct BulkEntry {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
}

/// Enumerates directories with `readdir(3)`, which returns many entries per
/// syscall and (where the filesystem supports it) the entry type in `d_type`
/// without a per-entry stat.
///
/// `FileManager.enumerator` issues a stat per URL, which is ~50x slower on
/// external volumes (observed: 47 s vs 0.12 s for ~62k entries on exFAT).
/// File sizes are fetched lazily by the caller only when needed.
enum FastDir {
    /// Walks `root` recursively and calls `onEntry(path, isDirectory, isSymlink)`
    /// for every entry. Hidden files are skipped unless `includeHidden`; an
    /// excluded directory (and its subtree) is skipped entirely.
    static func walk(root: String,
                     includeHidden: Bool,
                     exclude: ((String) -> Bool)?,
                     onEntry: (String, Bool, Bool) -> Void) {
        var stack = [root]
        while let dir = stack.popLast() {
            guard let handle = opendir(dir) else { continue }
            defer { closedir(handle) }

            while let ent = readdir(handle) {
                let name = withUnsafeBytes(of: ent.pointee.d_name) { raw -> String in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." { continue }
                // AppleDouble sidecars (._*) and .DS_Store are not user files;
                // external volumes are full of them, and indexing them would
                // double the work and pollute results.
                if name == ".DS_Store" || name.hasPrefix("._") { continue }
                if !includeHidden && name.hasPrefix(".") { continue }

                let path = dir.hasSuffix("/") ? dir + name : dir + "/" + name
                if let exclude, exclude(path) { continue }

                var isDir = false
                var isSymlink = false
                switch Int32(ent.pointee.d_type) {
                case DT_DIR: isDir = true
                case DT_LNK: isSymlink = true
                case DT_UNKNOWN:
                    var st = stat()
                    if lstat(path, &st) == 0 {
                        let fmt = st.st_mode & S_IFMT
                        isDir = (fmt == S_IFDIR)
                        isSymlink = (fmt == S_IFLNK)
                    }
                default:
                    break
                }

                // Symlinked directories are not descended into (loop safety);
                // symlinked files are kept.
                if isDir && isSymlink { continue }
                onEntry(path, isDir, isSymlink)
                if isDir { stack.append(path) }
            }
        }
    }
}
