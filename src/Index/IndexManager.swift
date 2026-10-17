import Foundation

// MARK: - Index CLI management

/// One-shot index maintenance used by `mff index rebuild|clean|status`. Operates
/// directly on the per-volume shard files without starting the daemon.
enum IndexManager {

    /// Directories/files under the index root.
    static func allFiles() -> [String] {
        let dir = IndexPaths.directory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.map { dir + "/" + $0 }
    }

    /// Rebuilds the shard for every configured, mounted volume. Passing `only`
    /// restricts it to volumes whose mount path contains that string.
    @discardableResult
    static func rebuild(config: ConfigFile, only: String? = nil) -> Int {
        IndexPaths.ensureDirectory()
        var volumes = IndexResolver(config: config).volumesToIndex()
        if let only, !only.isEmpty {
            volumes = volumes.filter { $0.path.contains(only) }
        }
        guard !volumes.isEmpty else {
            fputs("\(kAppName): no volumes to index (check [index] volumes)\n", stderr)
            return 0
        }
        var manifest = IndexManifest.load(from: URL(fileURLWithPath: IndexPaths.manifestFile()))
            ?? IndexManifest()
        var total = 0
        for vol in volumes {
            fputs("\(kAppName): building \(vol.path) (\(vol.fs))…\n", stderr)
            let started = Date()
            let built = FileIndex.build(roots: [vol.path],
                                        exclude: IndexResolver.effectiveExclude(config),
                                        includeHidden: true,
                                        onProgress: ProgressLine.prefix("indexing \(vol.name)"))
            ProgressLine.clear()
            let shardURL = URL(fileURLWithPath: IndexPaths.shardFile(id: vol.id))
            do {
                try built.save(to: shardURL)
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: IndexPaths.overlayFile(id: vol.id)))
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                print("\(kAppName): \(vol.path): \(built.count) entries in \(ms) ms — done")
                total += built.count
                manifest.volumes.removeAll { $0.id == vol.id }
                manifest.volumes.append(.init(id: vol.id, path: vol.path, fs: vol.fs,
                                              builtAt: built.builtAt.timeIntervalSince1970,
                                              lastEventID: 0, count: built.count))
            } catch {
                fputs("\(kAppName): cannot write \(shardURL.path): \(error.localizedDescription)\n", stderr)
                return -1
            }
        }
        // Written by this build, so the daemon keeps using it instead of
        // rebuilding for a version mismatch.
        manifest.appVersion = kAppVersion
        manifest.save(to: URL(fileURLWithPath: IndexPaths.manifestFile()))
        print("\(kAppName): \(IndexPaths.directory())")
        return total
    }

    /// Stops a running daemon by sending SIGTERM to the pid reported by PING.
    @discardableResult
    static func stop() -> Bool {
        guard let probe = IndexClient().probe() else { return false }
        // Never signal 0/1 (a malformed reply must not touch init or a group).
        guard probe.pid > 1, probe.pid <= Int(Int32.max) else { return false }
        return kill(pid_t(probe.pid), SIGTERM) == 0
    }

    /// Deletes every index file (manifest, shards, overlays, socket).
    @discardableResult
    static func clean() -> Int {
        var removed = 0
        for path in allFiles() {
            if (try? FileManager.default.removeItem(atPath: path)) != nil { removed += 1 }
        }
        return removed
    }

    /// Prints daemon state and the per-volume report.
    static func status() {
        let client = IndexClient()
        if let ping = client.probe() {
            print("daemon: running (pid \(ping.pid), state \(ping.state), \(ping.count) entries)")
            for v in client.volumes() {
                print("  volume \(v.path) [\(v.state)] \(v.entries) entries  (\(v.id))")
            }
            return
        }
        print("daemon: not running")

        let url = URL(fileURLWithPath: IndexPaths.manifestFile())
        guard let manifest = IndexManifest.load(from: url) else {
            print("index: none at \(IndexPaths.directory())")
            return
        }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        print("index: \(IndexPaths.directory())")
        let builtBy = manifest.appVersion.isEmpty ? "unknown (older mff)" : manifest.appVersion
        print("  built by mff \(builtBy)\(manifest.needsVersionRebuild ? " — will rebuild for \(kAppVersion)" : "")")
        for v in manifest.volumes {
            let shard = URL(fileURLWithPath: IndexPaths.shardFile(id: v.id))
            let size = (try? FileManager.default.attributesOfItem(atPath: shard.path)[.size] as? Int) ?? 0
            let mounted = FileManager.default.fileExists(atPath: v.path)
            print("  volume \(v.path)\(mounted ? "" : " (not mounted)")")
            print("    id: \(v.id)  fs: \(v.fs)  entries: \(v.count)")
            print("    size: \(byteString(size ?? 0))  built: \(fmt.string(from: Date(timeIntervalSince1970: v.builtAt)))")
            print("    lastEventId: \(v.lastEventID)")
        }
    }

    private static func byteString(_ bytes: Int) -> String {
        let units = ["B", "KiB", "MiB", "GiB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }
}
