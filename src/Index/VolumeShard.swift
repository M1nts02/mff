import Foundation

// MARK: - Volume identity

/// A mounted volume, identified by UUID so a path reused by a different disk is
/// not mistaken for the same one.
struct VolumeInfo {
    let path: String
    /// Stable identity: the volume UUID when available, else a path-derived id.
    let id: String
    /// e.g. "apfs", "exfat", "hfs", "ntfs" (lowercased, best effort).
    let fs: String
    /// Whether the filesystem delivers FSEvents (APFS/HFS+ do; exFAT/NTFS don't).
    let supportsEvents: Bool

    /// e.g. `/Volumes/Sakura` -> `Sakura`.
    var name: String { (path as NSString).lastPathComponent }
}

enum VolumeIdentity {
    /// Describes the volume mounted at `path`.
    static func info(for path: String) -> VolumeInfo? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey, .volumeIsLocalKey, .volumeLocalizedFormatDescriptionKey
        ]
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys)
        let uuid = values?.volumeUUIDString
        let format = (values?.volumeLocalizedFormatDescription ?? "").lowercased()
        let local = values?.volumeIsLocal ?? true
        // Fall back to the mount path when the FS exposes no UUID.
        let id = uuid ?? "path:" + path
        let fs = describe(fsDescription: format, isLocal: local)
        let supportsEvents = fs == "apfs" || fs == "hfs" || fs == "hfs+"
        return VolumeInfo(
            path: path,
            id: id,
            fs: fs,
            supportsEvents: supportsEvents
        )
    }

    private static func describe(fsDescription: String, isLocal: Bool) -> String {
        if !isLocal { return "network" }
        if fsDescription.contains("apfs") { return "apfs" }
        if fsDescription.contains("exfat") { return "exfat" }
        if fsDescription.contains("ntfs") { return "ntfs" }
        if fsDescription.contains("hfs") { return "hfs" }
        if fsDescription.contains("ms-dos") || fsDescription.contains("fat") { return "fat" }
        return fsDescription.isEmpty ? "unknown" : fsDescription
    }

    /// All currently mounted volumes (hidden ones skipped).
    static func mounted() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let p = url.path
            // Skip the read-only system-volume duplicates and the boot symlink.
            if p.hasPrefix("/System/Volumes/") && p != "/System/Volumes/Data" { return nil }
            if p.hasPrefix("/Volumes/"),
               URL(fileURLWithPath: p).resolvingSymlinksInPath().path == "/" { return nil }
            return info(for: p)
        }
    }
}

// MARK: - Per-volume shard state

enum ShardState: String {
    /// Not mounted right now.
    case absent
    /// Full build in progress (no data yet).
    case building
    /// Serving from base + overlay.
    case ready
    /// Rebuilding in the background while the previous data keeps serving.
    case rebuilding
    /// Shard unreadable / corrupt; a rebuild is required.
    case broken
}

/// One **root**'s index: an immutable base file plus a mutable overlay.
///
/// A root is usually a whole volume (`/`, `/Volumes/Sakura`) but may be a
/// subdirectory (e.g. `~` or a configured path). The shard id combines the
/// volume UUID with the root path, so two roots on the same disk stay separate
/// while a disk swap (different UUID) is still detected.
final class VolumeShard {
    let volume: VolumeInfo
    var state: ShardState
    var index: FileIndex?
    let overlay = IndexOverlay()
    /// FSEvents checkpoint: replay starts here after a restart.
    var lastEventID: UInt64 = 0
    /// Entries in the base index (for status output).
    var baseCount: Int { index?.count ?? 0 }
    var totalCount: Int { baseCount + overlay.addedCount - overlay.deadCount }

    init(volume: VolumeInfo, state: ShardState) {
        self.volume = volume
        self.state = state
    }

    var isServing: Bool {
        switch state {
        case .ready, .rebuilding: return index != nil
        default: return false
        }
    }
}

// MARK: - Manifest (persisted volume registry)

/// The persisted list of volumes and their shard state. Rewritten atomically
/// whenever a volume mounts/unmounts or a shard is rebuilt.
struct IndexManifest: Codable {
    struct Entry: Codable {
        var id: String
        var path: String
        var fs: String
        var builtAt: Double
        var lastEventID: UInt64
        var count: Int
    }

    /// Bumped when the manifest layout or the shard semantics change.
    var format: Int = 10
    /// The `kAppVersion` that wrote this manifest. An index built by a
    /// different release is rebuilt automatically, even if `format` and the
    /// shard `FileIndex.formatVersion` still match (index content is derived
    /// from the binary's file classification, exclude rules and matcher, so a
    /// new build means a new index). Old manifests without it decode as "".
    var appVersion: String = ""
    var volumes: [Entry] = []

    /// True when the manifest was written by a different app version.
    var needsVersionRebuild: Bool { appVersion != kAppVersion }

    static func load(from url: URL) -> IndexManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let manifest = try? JSONDecoder().decode(IndexManifest.self, from: data)
        // Only the first load is surprising (a user-update rebuild); afterwards
        // the file is rewritten with the running version.
        if let manifest, manifest.needsVersionRebuild {
            fputs("\(kAppName): index was built by \(manifest.appVersion.isEmpty ? "an older mff" : "mff \(manifest.appVersion)");"
                  + " rebuilding for \(kAppVersion)\n", stderr)
        }
        return manifest
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        AtomicFile.write(data, to: url)
    }
}

// MARK: - Atomic file writes

enum AtomicFile {
    /// Writes via a temp file in the same directory, then `rename(2)`.
    static func write(_ data: Data, to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
