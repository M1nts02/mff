import Foundation

// MARK: - Which volumes to index

/// Decides the set of roots the index covers, from `[index]` in config.toml.
///
/// Policy (per the agreed default): the built-in data volume is indexed; external
/// volumes are **not** indexed unless explicitly listed in
/// `[index] external_volumes`. Filesystems without change events (exFAT/NTFS,
/// network) are skipped even when listed, since we cannot keep them fresh.
struct IndexResolver {
    let config: ConfigFile

    /// The roots to walk when building the index.
    func rootsToIndex() -> [String] {
        var roots: [String] = []

        // Built-in volumes.
        switch config.indexVolumes {
        case "none", "off", "false":
            break
        case "auto", "", "true", "all":
            // `auto` indexes the home tree (what a launcher mostly searches);
            // indexing whole internal volumes is opt-in via an explicit path.
            roots.append(FileManager.default.homeDirectoryForCurrentUser.path)
        default:
            // A comma-separated list of paths, or a single path.
            roots.append(contentsOf: splitList(config.indexVolumes).filter { isDirectory($0) })
        }

        // External volumes: off unless explicitly enabled. Filesystems without
        // FSEvents (exFAT/NTFS, network) are still indexed — they just cannot be
        // kept fresh live (staleness rebuild + manual `index rebuild` cover it).
        switch config.indexExternalVolumes {
        case "none", "off", "false", "":
            break
        case "all", "auto", "true":
            roots.append(contentsOf: externalVolumes())
        default:
            roots.append(contentsOf: splitList(config.indexExternalVolumes).filter { isDirectory($0) })
        }

        // De-duplicate while preserving order.
        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted }
    }

    /// One entry per configured root, each bound to its volume's identity.
    ///
    /// `VolumeInfo.path` is the **root path** being indexed; `VolumeInfo.id` is
    /// `volumeUUID#rootPath`, so two roots on the same disk are distinct shards
    /// while a disk swap (new UUID) is detected.
    func volumesToIndex() -> [VolumeInfo] {
        var out: [VolumeInfo] = []
        var seen = Set<String>()
        for root in rootsToIndex() {
            let volPath = Self.volumeMountPoint(for: root)
            guard let vol = VolumeIdentity.info(for: volPath) else { continue }
            let rootPath = (root as NSString).standardizingPath
            let id = vol.id + "#" + rootPath
            guard seen.insert(id).inserted else { continue }
            out.append(VolumeInfo(path: rootPath, id: id, fs: vol.fs,
                                  supportsEvents: vol.supportsEvents))
        }
        return out
    }

    /// The mount point (`/`, `/Volumes/X`, ...) containing `path`.
    static func volumeMountPoint(for path: String) -> String {
        var probe = path
        while probe.count > 1 {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: probe),
               let dev = attrs[.systemNumber] as? NSNumber {
                _ = dev
            }
            if (try? FileManager.default.attributesOfItem(atPath: probe)) != nil,
               let values = try? URL(fileURLWithPath: probe).resourceValues(forKeys: [.volumeIsRootFileSystemKey]),
               values.volumeIsRootFileSystem == true {
                return probe
            }
            let parent = (probe as NSString).deletingLastPathComponent
            if parent == probe || parent.isEmpty { break }
            probe = parent
        }
        // Fallback: a mounted volume whose path prefixes this one.
        let mounted = VolumeIdentity.mounted().map { $0.path }.sorted { $0.count > $1.count }
        for m in mounted where path == m || path.hasPrefix(m == "/" ? "/" : m + "/") { return m }
        return "/"
    }

    /// Directories excluded from `volumes = "auto"` because they are caches /
    /// app data, not user files (they dominate ~/Library). Always applied on top
    /// of `[index] exclude`.
    static let autoExclude: [String] = [
        "**/Library/Caches", "**/Library/Containers", "**/Library/Application Support",
        "**/Library/Developer", "**/Library/Logs", "**/Library/Mobile Documents",
        "**/node_modules", "**/DerivedData", "**/.git", "**/.build", "**/.Trash"
    ]

    /// The exclude patterns to actually use for indexing: the built-in cache
    /// exclusions plus `[index] exclude` from config.toml.
    static func effectiveExclude(_ config: ConfigFile) -> [String] {
        var seen = Set<String>()
        return (autoExclude + config.indexExclude).filter { seen.insert($0).inserted }
    }

    /// Mounted external volumes. Includes non-FSEvents filesystems (exFAT/NTFS).
    private func externalVolumes() -> [String] {
        mountedVolumes().filter { isExternal($0) }
    }

    private func mountedVolumes() -> [String] {
        let fm = FileManager.default
        guard let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                 options: [.skipHiddenVolumes]) else {
            return ["/"]
        }
        return volumes.map { $0.path }.filter { path in
            // Skip the read-only system-volume duplicates, but keep Data.
            if path.hasPrefix("/System/Volumes/") && path != "/System/Volumes/Data" { return false }
            // Skip the "/Volumes/Macintosh HD -> /" symlink.
            if path.hasPrefix("/Volumes/") {
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                if resolved == "/" { return false }
            }
            return true
        }
    }

    /// Whether a volume is external. Unknown/internal volume info is treated as
    /// internal so the built-in set is never accidentally empty.
    private func isExternal(_ path: String) -> Bool {
        if let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeIsInternalKey]),
           let internalFlag = values.volumeIsInternal {
            return !internalFlag
        }
        // Fall back to the mount point: anything under /Volumes (not the boot
        // disk symlink) is external.
        return path.hasPrefix("/Volumes/")
    }

    private func splitList(_ value: String) -> [String] {
        value.split(separator: ",").map {
            ($0 as Substring).trimmingCharacters(in: .whitespaces)
        }.map { PathExpansion.expand($0) }.filter { !$0.isEmpty }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - Path expansion

/// Expands `~`, `${HOME}` and `$HOME` at the start of a path/pattern. `${VAR}`
/// for other variables is left untouched.
enum PathExpansion {
    static func expand(_ raw: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("${HOME}") { s = home + s.dropFirst("${HOME}".count) }
        else if s.hasPrefix("$HOME") { s = home + s.dropFirst("$HOME".count) }
        else if s.hasPrefix("~") { s = (s as NSString).expandingTildeInPath }
        return s
    }
}
