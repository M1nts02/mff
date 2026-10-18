import Foundation
import AppKit

// MARK: - Index daemon

/// A resident process that owns the filename index and answers search queries
/// over a Unix socket. Started with `mff --index-daemon`.
///
/// The index is kept **per volume** (`VolumeShard`): one immutable base file
/// plus an incremental overlay each. That makes mount/unmount cheap (only that
/// volume changes), lets a shard be rebuilt in the background while its old data
/// keeps serving, and lets a restarted daemon replay FSEvents from its saved
/// checkpoint. Any volume that is not ready is simply skipped and reported as
/// `partial`, so clients can fall back to a live walk.
final class IndexDaemon {
    /// The live `config.toml`. Mutable so edits (e.g. adding
    /// `external_volumes = "all"`) take effect without restarting the daemon.
    private var config: ConfigFile
    /// Path the config was loaded from (re-read on change / per search).
    private let configPath: String
    private var listenFD: Int32 = -1
    /// Guards `shards`, `manifest` and each shard's overlay.
    private let lock = NSLock()
    private var shards: [String: VolumeShard] = [:]          // volume id -> shard
    private var shardOrder: [String] = []                    // stable order for search
    private var watchers: [String: FSEventWatcher] = [:]     // volume id -> watcher
    private var manifest = IndexManifest()
    /// Exclusive lock fd guarding against a second daemon.
    private var lockFD: Int32 = -1
    /// Debounced overlay persistence.
    private var overlaySaveWork: [String: DispatchWorkItem] = [:]

    init(config: ConfigFile, configPath: String) {
        self.config = config
        self.configPath = configPath
        IndexPaths.ensureDirectory()
    }

    // MARK: - Startup

    /// Loads (or creates) the shard for every configured, currently mounted
    /// volume, then starts background builds for the ones that need it.
    func prepareIndex(forceRebuild: Bool) {
        var forceRebuild = forceRebuild
        manifest = IndexManifest.load(from: URL(fileURLWithPath: IndexPaths.manifestFile()))
            ?? IndexManifest()

        // An index written by another mff release is rebuilt wholesale: file
        // classification, exclude rules and stored metadata may have changed,
        // so even a shard with the same on-disk format is stale. The first
        // `saveManifestLocked` stamps the new version.
        let versionStale = manifest.needsVersionRebuild
        if versionStale {
            forceRebuild = true
        }

        let volumes = IndexResolver(config: config).volumesToIndex()
        if volumes.isEmpty {
            fputs("\(kAppName): no volumes to index\n", stderr)
            return
        }

        for vol in volumes {
            let shard = VolumeShard(volume: vol, state: .building)
            lock.lock()
            shards[vol.id] = shard
            shardOrder.append(vol.id)
            lock.unlock()

            let existing = manifest.volumes.first { $0.id == vol.id }
            let shardURL = URL(fileURLWithPath: IndexPaths.shardFile(id: vol.id))
            let overlayURL = URL(fileURLWithPath: IndexPaths.overlayFile(id: vol.id))

            if !forceRebuild, existing != nil, let loaded = FileIndex.load(from: shardURL) {
                shard.index = loaded
                shard.lastEventID = existing?.lastEventID ?? 0
                _ = shard.overlay.load(from: overlayURL)
                shard.state = .ready
                fputs("\(kAppName): loaded \(vol.path): \(loaded.count) entries\n", stderr)
                startWatching(shard)
                // Replay from the checkpoint: FSEvents delivers everything that
                // happened while the daemon was down; if events were dropped the
                // watcher marks a rescan.
                continue
            }

            fputs("\(kAppName): building \(vol.path)…\n", stderr)
            startBuild(shard)
        }
    }

    // MARK: - Building one volume

    private func startBuild(_ shard: VolumeShard) {
        let root = shard.volume.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let started = Date()
            let built = FileIndex.build(roots: [root],
                                        exclude: IndexResolver.effectiveExclude(self.config),
                                        includeHidden: true,
                                        onProgress: ProgressLine.prefix("indexing \(shard.volume.name)"))
            ProgressLine.clear()
            let shardURL = URL(fileURLWithPath: IndexPaths.shardFile(id: shard.volume.id))
            do {
                try built.save(to: shardURL)
                fputs("\(kAppName): built \(shard.volume.path): \(built.count) entries in \(Int(Date().timeIntervalSince(started) * 1000)) ms — done\n", stderr)
            } catch {
                fputs("\(kAppName): cannot write \(shardURL.path): \(error.localizedDescription)\n", stderr)
                self.lock.lock(); shard.state = .broken; self.lock.unlock()
                return
            }

            self.lock.lock()
            shard.index = built
            shard.overlay.reset()
            shard.state = .ready
            self.saveManifestLocked()
            self.lock.unlock()

            try? FileManager.default.removeItem(at: URL(fileURLWithPath: IndexPaths.overlayFile(id: shard.volume.id)))
            self.startWatching(shard)
        }
    }

    // MARK: - FSEvents per volume

    /// (Re)starts the FSEvents stream for a shard. Returns false when the
    /// volume cannot be watched.
    @discardableResult
    private func startWatching(_ shard: VolumeShard) -> Bool {
        guard shard.volume.supportsEvents else {
            fputs("\(kAppName): \(shard.volume.path): no FSEvents (\(shard.volume.fs)); index is static\n", stderr)
            return false
        }
        lock.lock()
        let alreadyWatched = watchers[shard.volume.id] != nil
        lock.unlock()
        if alreadyWatched { return true }
        lock.lock()
        let since = shard.lastEventID
        lock.unlock()
        let watcher = FSEventWatcher(root: shard.volume.path, sinceEventID: since) { [weak self] batch in
            self?.handleBatch(batch, shardID: shard.volume.id)
        }
        if watcher.start() {
            lock.lock(); watchers[shard.volume.id] = watcher; lock.unlock()
            return true
        }
        fputs("\(kAppName): \(shard.volume.path): FSEvents unavailable\n", stderr)
        return false
    }

    private func stopWatching(_ id: String) {
        lock.lock()
        let w = watchers.removeValue(forKey: id)
        lock.unlock()
        w?.stop()
    }

    private func handleBatch(_ batch: FSEventWatcher.Batch, shardID: String) {
        if batch.needsRescan {
            rebuildVolume(shardID)
            return
        }
        // Directory-granularity rescan of the affected parents.
        var dirs = Set<String>()
        for p in batch.changed {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) {
                dirs.insert(isDir.boolValue ? p : (p as NSString).deletingLastPathComponent)
            } else {
                dirs.insert((p as NSString).deletingLastPathComponent)
            }
        }
        lock.lock()
        guard let shard = shards[shardID], shard.isServing else { lock.unlock(); return }
        for dir in dirs where !dir.isEmpty { rescanDirectory(dir, shard: shard) }
        if batch.lastEventID > shard.lastEventID { shard.lastEventID = batch.lastEventID }
        let compact = shard.overlay.shouldCompact()
        saveManifestLocked()
        lock.unlock()

        scheduleOverlaySave(shardID)
        if compact { rebuildVolume(shardID) }
    }

    /// Rebuilds one volume in the background; the old data keeps serving until
    /// the new index is ready.
    private func rebuildVolume(_ id: String) {
        lock.lock()
        guard let existing = shards[id], existing.state != .building else { lock.unlock(); return }
        existing.state = .rebuilding
        lock.unlock()
        fputs("\(kAppName): rebuilding \(existing.volume.path)\n", stderr)
        stopWatching(id)
        startBuild(existing)
    }

    // MARK: - Incremental diff of one directory

    private func rescanDirectory(_ dir: String, shard: VolumeShard) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else {
            shard.overlay.removeSubtree(dir)
            return
        }
        let eff = IndexResolver.effectiveExclude(config)
        let matcher = eff.isEmpty ? nil : ExcludeMatcher(patterns: eff)
        var present = Set<String>()
        for name in names {
            let path = (dir as NSString).appendingPathComponent(name)
            if let matcher, matcher.matches(path) { continue }
            guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else { continue }
            let isDir = values.isDirectory ?? false
            let isSymlink = values.isSymbolicLink ?? false
            if isDir && isSymlink { continue }
            present.insert(path)
            if let existing = currentEntry(path, shard: shard), existing.isDirectory == isDir { continue }
            let isBinary = isDir ? false : FileProbe.isBinary(url: URL(fileURLWithPath: path))
            let category = FileTypeRegistry.category(for: (path as NSString).pathExtension)
            var text = isDir ? nil
                : MediaMetadata.searchableText(for: URL(fileURLWithPath: path), category: category)
            if let t = text { text = t.replacingOccurrences(of: "\n", with: " ") }
            shard.overlay.upsert(IndexEntry(path: path, isDirectory: isDir,
                                            isBinary: isBinary, binaryText: text))
        }
        for entry in entries(inDirectory: dir, shard: shard) where !present.contains(entry.path) {
            shard.overlay.remove(entry.path)
        }
    }

    private func currentEntry(_ path: String, shard: VolumeShard) -> IndexEntry? {
        if shard.overlay.isUnderDead(path) { return nil }
        if let added = shard.overlay.allAdded().first(where: { $0.path == path }) { return added }
        guard let index = shard.index, let i = index.index(of: path) else { return nil }
        let binary = index.binaryContent(at: i)
        return IndexEntry(path: path, isDirectory: index.isDirectory(at: i),
                          isBinary: index.isBinary(at: i), binaryText: binary.text)
    }

    private func entries(inDirectory dir: String, shard: VolumeShard) -> [IndexEntry] {
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        var out: [IndexEntry] = []
        if let index = shard.index {
            for e in index.allEntries() where e.path.hasPrefix(prefix)
                && !e.path.dropFirst(prefix.count).contains("/") {
                if !shard.overlay.isUnderDead(e.path) { out.append(e) }
            }
        }
        for e in shard.overlay.allAdded() where e.path.hasPrefix(prefix)
            && !e.path.dropFirst(prefix.count).contains("/") {
            out.append(e)
        }
        return out
    }

    private func scheduleOverlaySave(_ id: String) {
        lock.lock()
        overlaySaveWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveOverlay(id) }
        overlaySaveWork[id] = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func saveOverlay(_ id: String) {
        lock.lock()
        guard let shard = shards[id] else { lock.unlock(); return }
        lock.unlock()
        let url = URL(fileURLWithPath: IndexPaths.overlayFile(id: id))
        lock.lock()
        shard.overlay.save(to: url)
        lock.unlock()
    }

    // MARK: - Serving

    func run() {
        let path = IndexPaths.socketPath()
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            fputs("\(kAppName): index-daemon: cannot create socket\n", stderr); exit(1)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            fputs("\(kAppName): index-daemon: socket path too long\n", stderr); exit(1)
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                path.withCString { src in strcpy(dst, src) }
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(listenFD, 16) == 0 else {
            fputs("\(kAppName): index-daemon: cannot bind \(path)\n", stderr); exit(1)
        }
        fputs("\(kAppName): index-daemon listening on \(path)\n", stderr)

        installSignalHandlers()
        installMountObservers()
        observeAppActivation()

        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(clientFD)
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        // Pick up config edits even while brew services keeps the process alive.
        reloadConfigIfChanged()
        var reader = SocketReader(fd: fd)
        while let line = reader.nextLine() {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let command = parts.first.map(String.init) ?? ""
            switch command {
            case "PING":
                let (state, volCount, entries) = summary()
                writeLine(fd, "PONG \(getpid()) \(state) \(volCount) \(entries)")
            case "SEARCH":
                handleSearch(fd: fd, payload: parts.count > 1 ? String(parts[1]) : "")
            case "ROOTS", "VOLUMES":
                writeVolumes(fd)
            case "QUIT":
                return
            default:
                writeLine(fd, "ERR unknown command")
            }
        }
    }

    /// (global state, volume count, total entries)
    private func summary() -> (String, Int, Int) {
        lock.lock(); defer { lock.unlock() }
        let vols = shardOrder.compactMap { shards[$0] }
        let entries = vols.reduce(0) { $0 + $1.totalCount }
        let state: String
        if vols.isEmpty {
            state = "empty"
        } else if vols.allSatisfy({ $0.state == .ready || $0.state == .rebuilding }) {
            state = "ready"
        } else {
            state = "partial"
        }
        return (state, vols.count, entries)
    }

    private func writeVolumes(_ fd: Int32) {
        lock.lock()
        let vols = shardOrder.compactMap { shards[$0] }.map {
            ($0.volume.id, $0.volume.path, $0.state.rawValue, $0.totalCount)
        }
        lock.unlock()
        for v in vols { writeLine(fd, "VOL \(v.0) \(v.1) \(v.2) \(v.3)") }
        writeLine(fd, "END")
    }

    /// Payload: `<mode> <prefixes> <excludes>\t<query>`.
    private func handleSearch(fd: Int32, payload: String) {
        let head: String
        let query: String
        if let tab = payload.firstIndex(of: "\t") {
            head = String(payload[..<tab]); query = String(payload[payload.index(after: tab)...])
        } else { head = payload; query = "" }

        let headParts = head.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        let mode = headParts.first.map(String.init) ?? "name"
        let prefixField = headParts.count > 1 ? String(headParts[1]) : ""
        let excludeField = headParts.count > 2 ? String(headParts[2]) : ""

        // Every prefix is tried in several equivalent spellings so a client
        // path matches the index no matter how it was written: standardized
        // (drops "." / ".." / trailing "/"), symlink-resolved (a `~/Downloads`
        // that is a symlink into another tree), and with FSEvents' `/private/...`
        // spelling.
        var prefixes: [String] = []
        for raw in prefixField.split(separator: ";").map(String.init) where !raw.isEmpty {
            var forms = [raw]
            forms.append((raw as NSString).standardizingPath)
            forms.append(URL(fileURLWithPath: raw).resolvingSymlinksInPath().path)
            for form in forms {
                var spellings = [form, form.hasSuffix("/") ? String(form.dropLast()) : form + "/"]
                // `/tmp` is a symlink to `/private/tmp`; some clients see one
                // spelling, FSEvents the other.
                if form.hasPrefix("/tmp/") { spellings.append("/private" + form) }
                if form.hasPrefix("/private/tmp/") {
                    let short = String(form.dropFirst("/private".count))
                    spellings.append(short)
                    spellings.append(short + "/")
                }
                prefixes.append(contentsOf: spellings.filter { !$0.isEmpty })
            }
        }
        let excludePatterns = excludeField.split(separator: ";").map(String.init).filter { !$0.isEmpty }
        let excludeMatcher = excludePatterns.isEmpty ? nil : ExcludeMatcher(patterns: excludePatterns)
        let tokens = FuzzyMatcher.tokenize(query)
        let contentMode = mode == "content"

        // Snapshot the serving shards. The base is iterated **by index** below
        // (no materialization): on a fast local disk with hundreds of thousands
        // of entries, building IndexEntry/String for every item per query was
        // slower than a live walk.
        lock.lock()
        var views: [SearchView] = []
        var partial = false
        for id in shardOrder {
            guard let shard = shards[id] else { continue }
            guard shard.isServing, let base = shard.index else { partial = true; continue }
            views.append(SearchView(base: base, added: shard.overlay.allAdded(),
                                    overlay: shard.overlay))
        }
        lock.unlock()

        var matched = 0
        let out = LineWriter(fd: fd)

        // HIT/BIN lines end with a kind token (\tD directory, \tF file) so
        // clients never have to `stat` a hit path. BCONTENT is always a file
        // carrying metadata, so it never gets one.
        func kind(_ isDirectory: Bool) -> String { isDirectory ? "\tD" : "\tF" }

        func emit(path: String, isDirectory: Bool, isBinary: Bool, binaryText: String?) {
            if !prefixes.isEmpty, !prefixes.contains(where: { underPrefix(path, $0) }) { return }
            if let excludeMatcher, excludeMatcher.matches(path) { return }
            guard pathMatches(path: path, pathLower: path.lowercased(), isDirectory: isDirectory,
                              tokens: tokens, contentMode: contentMode,
                              binaryText: binaryText) else { return }
            if contentMode, !isDirectory {
                if let text = binaryText, !text.isEmpty {
                    let flat = text.replacingOccurrences(of: "\n", with: " ")
                    out.write("BCONTENT \(path)\t\(flat)"); matched += 1; return
                }
                if isBinary { out.write("BIN \(path)\tF"); matched += 1; return }
            }
            out.write("HIT \(path)\(kind(isDirectory))"); matched += 1
        }

        for view in views {
            let base = view.base
            for i in 0..<base.count {
                let path = base.path(at: i)
                if path.contains("\n") { continue }
                if view.overlay.isUnderDead(path) { continue }
                // Cheap pre-checks first: prefix/exclude before any object work.
                if !prefixes.isEmpty, !prefixes.contains(where: { underPrefix(path, $0) }) { continue }
                if let excludeMatcher, excludeMatcher.matches(path) { continue }
                let isDir = base.isDirectory(at: i)
                let binary = contentMode ? base.binaryContent(at: i) : nil
                guard pathMatches(path: path, pathLower: path.lowercased(), isDirectory: isDir,
                                  tokens: tokens, contentMode: contentMode,
                                  binaryText: binary?.text) else { continue }
                if contentMode, !isDir {
                    if let text = binary?.text, !text.isEmpty {
                        let flat = text.replacingOccurrences(of: "\n", with: " ")
                        out.write("BCONTENT \(path)\t\(flat)"); matched += 1; continue
                    }
                    if base.isBinary(at: i) { out.write("BIN \(path)\tF"); matched += 1; continue }
                }
                out.write("HIT \(path)\(kind(isDir))"); matched += 1
            }
            // Overlay entries (new/changed since the base).
            for entry in view.added {
                if entry.path.contains("\n") { continue }
                emit(path: entry.path, isDirectory: entry.isDirectory,
                     isBinary: entry.isBinary, binaryText: entry.binaryText)
            }
        }
        out.write("END \(matched) \(partial ? 1 : 0)")
        out.flush()
    }

    private func underPrefix(_ path: String, _ prefix: String) -> Bool {
        if path == prefix { return true }
        let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return path.hasPrefix(trimmed + "/")
    }

    /// True if `needle`'s characters occur in `haystack` in order.
    private static func containsSubsequence(_ haystack: String, _ needle: String) -> Bool {
        if needle.isEmpty { return true }
        var it = needle.makeIterator()
        guard var want = it.next() else { return true }
        for c in haystack {
            if c == want {
                if let next = it.next() { want = next } else { return true }
            }
        }
        return false
    }

    private func pathMatches(path: String, pathLower: String, isDirectory: Bool,
                             tokens: [String], contentMode: Bool,
                             binaryText: String?) -> Bool {
        if tokens.isEmpty { return true }
        // Cheap prefilter that never rejects a real fuzzy match: the term's
        // characters must appear **in order** in the path (a subsequence), which
        // is exactly the fuzzy rule. This skips building a SearchableItem (which
        // lowercases and copies the whole path) for most entries.
        for token in tokens {
            var body = token
            if body.hasPrefix("!") { continue }              // negations need the full pass
            if body.hasPrefix("'") { body.removeFirst() }
            if body.hasPrefix("^") || body.hasSuffix("$") || (body.hasPrefix(".") && body.count > 1) {
                continue                                      // name-only operators: full pass
            }
            if body.isEmpty { continue }
            if !Self.containsSubsequence(pathLower, body.lowercased()) { return false }
        }
        let item = SearchableItem(url: URL(fileURLWithPath: path), isDirectory: isDirectory)
        if FuzzyMatcher.match(query: tokens.joined(separator: "\t"), in: item, matchPath: true) != nil {
            return true
        }
        guard contentMode, !isDirectory, let text = binaryText, !text.isEmpty else { return false }
        let haystack = text.lowercased()
        for token in tokens {
            var body = token
            if body.hasPrefix("!") { body.removeFirst(); continue }
            if body.hasPrefix("'") { body.removeFirst() }
            if body.hasPrefix("^") || body.hasSuffix("$") || (body.hasPrefix(".") && body.count > 1) { return false }
            if body.isEmpty { continue }
            if haystack.range(of: body, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
        }
        return true
    }

    /// Re-checks the config whenever this user's GUI session becomes active.
    /// `brew services` starts the daemon at login, often before external disks
    /// are mounted (or before the config was edited); the next time mff is used
    /// the daemon catches up without a restart.
    private func observeAppActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.reloadConfigIfChanged()
            self.resumeMissingWatchers()
        }
    }

    /// Starts FSEvents for ready shards that have no watcher yet (covers disks
    /// mounted before the daemon and restarts that failed).
    private func resumeMissingWatchers() {
        lock.lock()
        let candidates = shards.values.filter { $0.state == .ready }
        lock.unlock()
        for shard in candidates { startWatching(shard) }
    }

    // MARK: - Config reload

    /// Re-reads `config.toml`. Returns true when the parsed values changed.
    @discardableResult
    private func reloadConfigIfChanged() -> Bool {
        guard FileManager.default.fileExists(atPath: configPath) else { return false }
        let fresh = ConfigFileLoader.load(path: configPath)
        // Repeat the parse warnings only when something actually changed.
        if !sameConfig(fresh, config), !fresh.warnings.isEmpty {
            for w in fresh.warnings { fputs("\(kAppName): config \(configPath): \(w)\n", stderr) }
        }
        guard !sameConfig(fresh, config) else { return false }
        fputs("\(kAppName): config changed; reloading \(configPath)\n", stderr)
        config = fresh
        applyConfigChanges()
        return true
    }

    /// Compares everything that affects the daemon (warnings/UI keys do not:
    /// they are printed once at load and would otherwise reload on every log).
    private func sameConfig(_ a: ConfigFile, _ b: ConfigFile) -> Bool {
        a.indexEnabled == b.indexEnabled
            && a.indexVolumes == b.indexVolumes
            && a.indexExternalVolumes == b.indexExternalVolumes
            && a.indexExclude == b.indexExclude
    }

    /// Reconciles shards with the (new) config: drops volumes no longer wanted
    /// (hidden immediately, files kept for a quick return) and starts builds for
    /// newly wanted volumes that are mounted.
    private func applyConfigChanges() {
        lock.lock()
        let wanted = IndexResolver(config: config).volumesToIndex()
        let wantedIDs = Set(wanted.map { $0.id })
        var dropped: [String] = []
        for (id, shard) in shards where !wantedIDs.contains(id) {
            shard.overlay.removeSubtree(shard.volume.path)
            shard.state = .absent
            dropped.append(id)
        }
        for id in dropped { shards.removeValue(forKey: id) }
        shardOrder.removeAll { dropped.contains($0) }
        var added: [VolumeInfo] = []
        for vol in wanted where shards[vol.id] == nil {
            let shard = VolumeShard(volume: vol, state: .building)
            shards[vol.id] = shard
            shardOrder.append(vol.id)
            added.append(vol)
        }
        lock.unlock()

        for id in dropped {
            stopWatching(id)
            fputs("\(kAppName): \(id): no longer indexed (config)\n", stderr)
        }
        resumeMissingWatchers()
        for vol in added {
            fputs("\(kAppName): \(vol.path): now indexed (config)\n", stderr)
            lock.lock()
            let shard = shards[vol.id]
            lock.unlock()
            if let shard { startBuild(shard) }
        }
    }

    // MARK: - Mount/unmount

    private func installMountObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            self?.volumeMounted(url.path)
        }
        nc.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: nil) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            self?.volumeUnmounted(url.path)
        }
    }

    private func volumeMounted(_ path: String) {
        guard let info = VolumeIdentity.info(for: path) else { return }
        let allowed = IndexResolver(config: config).volumesToIndex().contains { $0.id == info.id }
        lock.lock()
        let existing = shards[info.id]
        lock.unlock()

        if let current = existing, current.state == .ready {
            // Already serving this mount (daemon started with the disk mounted,
            // or it was configured at startup): just resume events from the
            // checkpoint.
            startWatching(current)
            return
        }
        if existing != nil {
            // The disk came back under the same id: its shard is on disk; reload
            // it and replay FSEvents from the checkpoint instead of re-walking.
            if let shard = reloadShard(info), startWatching(shard) || !info.supportsEvents {
                fputs("\(kAppName): \(path) remounted; resuming\n", stderr)
                return
            }
        }
        if allowed {
            fputs("\(kAppName): \(path) mounted; building\n", stderr)
            let shard = VolumeShard(volume: info, state: .building)
            lock.lock(); shards[info.id] = shard; shardOrder.append(info.id); lock.unlock()
            startBuild(shard)
        }
    }

    /// Loads an existing shard from disk (used after a remount).
    private func reloadShard(_ info: VolumeInfo) -> VolumeShard? {
        let shardURL = URL(fileURLWithPath: IndexPaths.shardFile(id: info.id))
        let overlayURL = URL(fileURLWithPath: IndexPaths.overlayFile(id: info.id))
        guard let loaded = FileIndex.load(from: shardURL) else { return nil }
        let shard = VolumeShard(volume: info, state: .ready)
        shard.index = loaded
        lock.lock()
        shard.lastEventID = manifest.volumes.first { $0.id == info.id }?.lastEventID ?? 0
        _ = shard.overlay.load(from: overlayURL)
        shards[info.id] = shard
        if !shardOrder.contains(info.id) { shardOrder.append(info.id) }
        lock.unlock()
        return shard
    }

    private func volumeUnmounted(_ path: String) {
        guard let info = VolumeIdentity.info(for: path) else { return }
        stopWatching(info.id)
        lock.lock()
        defer { lock.unlock() }
        guard let shard = shards[info.id] else { return }
        // Hide the volume's entries immediately; keep the shard files for a fast
        // remount.
        shard.overlay.removeSubtree(shard.volume.path)
        shard.overlay.save(to: URL(fileURLWithPath: IndexPaths.overlayFile(id: info.id)))
        shard.state = .absent
        shard.index = nil
        fputs("\(kAppName): \(path) unmounted\n", stderr)
    }

    // MARK: - Helpers

    /// Persists the manifest. Caller must hold `lock`.
    private func saveManifestLocked() {
        var m = IndexManifest()
        m.appVersion = kAppVersion
        for id in shardOrder {
            guard let shard = shards[id], let index = shard.index else { continue }
            m.volumes.append(.init(id: shard.volume.id, path: shard.volume.path,
                                   fs: shard.volume.fs,
                                   builtAt: index.builtAt.timeIntervalSince1970,
                                   lastEventID: shard.lastEventID,
                                   count: index.count))
        }
        manifest = m
        m.save(to: URL(fileURLWithPath: IndexPaths.manifestFile()))
    }

    /// Buffered socket writer: batches lines into one `write(2)` per flush.
    /// Per-line writes dominated large result sets (one syscall per hit).
    private final class LineWriter {
        private let fd: Int32
        private var buffer: [UInt8] = []
        private let flushAt = 64 * 1024

        init(fd: Int32) { self.fd = fd; buffer.reserveCapacity(flushAt + 4096) }

        func write(_ line: String) {
            buffer.append(contentsOf: line.utf8)
            buffer.append(0x0A)
            if buffer.count >= flushAt { flush() }
        }

        func flush() {
            guard !buffer.isEmpty else { return }
            buffer.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                var sent = 0
                while sent < buf.count {
                    let n = Darwin.write(fd, base + sent, buf.count - sent)
                    if n <= 0 { break }
                    sent += n
                }
            }
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private func writeLine(_ fd: Int32, _ line: String) {
        var bytes = Array(line.utf8)
        bytes.append(0x0A)
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var sent = 0
            while sent < buf.count {
                let n = Darwin.write(fd, base + sent, buf.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private func installSignalHandlers() {
        signal(SIGPIPE, SIG_IGN)
        let cleanup: @convention(c) (Int32) -> Void = { _ in
            unlink(IndexPaths.socketPath())
            exit(0)
        }
        signal(SIGINT, cleanup)
        signal(SIGTERM, cleanup)
    }

    /// Takes an exclusive `flock` on the lock file. Returns false if another
    /// process already holds it. Call this *before* any expensive index work.
    func claimSingleInstance() -> Bool {
        if lockFD >= 0 { return true }
        IndexPaths.ensureDirectory()
        let fd = open(IndexPaths.lockPath(), O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        lockFD = fd
        return true
    }
}

/// A snapshot of one shard used during a search: the immutable base plus the
/// overlay entries added on top. `overlay` is consulted for tombstones.
private struct SearchView {
    let base: FileIndex
    let added: [IndexEntry]
    let overlay: IndexOverlay
}

/// Buffered line reader over a socket fd.
struct SocketReader {
    let fd: Int32
    private var buffer = [UInt8]()
    private var cursor = 0

    init(fd: Int32) { self.fd = fd }

    mutating func nextLine() -> String? {
        while true {
            if let nl = buffer[cursor...].firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[cursor..<nl], as: UTF8.self)
                cursor = nl + 1
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}
