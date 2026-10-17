import Foundation

// MARK: - Item sources

/// A searchable input: stdin lines, a filesystem scan, or an app scan.
/// Each source streams `SearchableItem`s to the main queue in batches.
protocol ItemSource {
    func load(
        onBatch: @escaping @MainActor ([SearchableItem]) -> Void,
        onComplete: @escaping @MainActor () -> Void
    )
}

/// Reads newline-separated items from stdin (fzf-style). Depending on `kind`,
/// each line is either kept as a raw string or resolved to a filesystem path
/// so it can be browsed (and previewed / opened) like a file or app result.
struct StdinSource: ItemSource {
    var kind: Config.StdinKind = .lines
    var typeFilter = TypeFilter()
    var namePattern: String?
    /// Search-time exclude patterns (`exclude` in config + `--exclude`).
    var exclude: [String] = []

    func load(onBatch: @escaping @MainActor ([SearchableItem]) -> Void,
              onComplete: @escaping @MainActor () -> Void) {
        if isatty(FileHandle.standardInput.fileDescriptor) != 0 {
            fputs("mff: no input on stdin. Run without --stdin to search the current directory, or pipe items in.\n", stderr)
            exit(1)
        }

        let kind = self.kind
        let typeFilter = self.typeFilter
        let loweredName = namePattern?.lowercased()
        let matcher = exclude.isEmpty ? nil : ExcludeMatcher(patterns: exclude)

        DispatchQueue.global(qos: .userInitiated).async {
            let handle = FileHandle.standardInput
            let chunkSize = 64 * 1024
            var pending = ""
            var batch: [String] = []
            batch.reserveCapacity(512)

            func flush() {
                guard !batch.isEmpty else { return }
                let chunk = batch
                batch.removeAll(keepingCapacity: true)
                let items = chunk.compactMap { line -> SearchableItem? in
                    switch kind {
                    case .lines:
                        return SearchableItem(text: line)
                    case .files:
                        guard let item = StdinSource.fileItem(
                            for: line,
                            typeFilter: typeFilter,
                            loweredName: loweredName
                        ) else { return nil }
                        if let matcher, matcher.matches(item.raw) { return nil }
                        return item
                    }
                }
                guard !items.isEmpty else { return }
                DispatchQueue.main.async { onBatch(items) }
            }
            while true {
                let data = handle.readData(ofLength: chunkSize)
                if data.isEmpty { break }
                var text = pending + (String(data: data, encoding: .utf8) ?? "")
                pending = ""

                while let range = text.range(of: "\n") {
                    let line = String(text[..<range.lowerBound])
                    text = String(text[range.upperBound...])
                    if !line.isEmpty {
                        batch.append(line)
                        if batch.count >= 512 { flush() }
                    }
                }
                pending = text
            }

            if !pending.isEmpty { batch.append(pending) }
            flush()
            DispatchQueue.main.async { onComplete() }
        }
    }

    /// Resolves a stdin line to a file item. Tilde and relative paths are
    /// expanded so `zoxide`-style output and hand-typed paths both work.
    static func fileItem(for line: String,
                                 typeFilter: TypeFilter,
                                 loweredName: String?) -> SearchableItem? {
        var path = (line as NSString).expandingTildeInPath
        if !(path as NSString).isAbsolutePath {
            path = (FileManager.default.currentDirectoryPath as NSString)
                .appendingPathComponent(path)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let isDir = isDirectory(url.path)

        if let loweredName, !url.lastPathComponent.lowercased().contains(loweredName) {
            return nil
        }
        if !typeFilter.isEmpty,
           !typeFilter.matches(path: url.path, ext: url.pathExtension, isDirectory: isDir) {
            return nil
        }
        return SearchableItem(url: url, isDirectory: isDir)
    }
}

/// Recursively enumerates the filesystem for files matching a type/name filter.
struct FileSource: ItemSource {
    let paths: [String]
    let typeFilter: TypeFilter
    let namePattern: String?
    let includeHidden: Bool
    /// Search-time exclude patterns (`exclude` in config + `--exclude`).
    var exclude: [String] = []

    func load(onBatch: @escaping @MainActor ([SearchableItem]) -> Void,
              onComplete: @escaping @MainActor () -> Void) {
        FileIndexer.enumerate(
            paths: paths,
            typeFilter: typeFilter,
            namePattern: namePattern,
            includeHidden: includeHidden,
            exclude: exclude,
            onBatch: onBatch,
            onComplete: onComplete
        )
    }
}

/// Recursively enumerates files and indexes their text contents for content
/// search. Binary files are skipped. Kept separate from `FileSource` so the
/// two modes never share processing logic.
struct ContentSource: ItemSource {
    let paths: [String]
    let typeFilter: TypeFilter
    let namePattern: String?
    let includeHidden: Bool
    let maxFileSize: Int
    /// `--content` (text) and `--binary` (binary-file contents); both may be on.
    let readText: Bool
    let readBinary: Bool
    /// Search-time exclude patterns (`exclude` in config + `--exclude`).
    var exclude: [String] = []

    func load(onBatch: @escaping @MainActor ([SearchableItem]) -> Void,
              onComplete: @escaping @MainActor () -> Void) {
        ContentIndexer.enumerate(
            paths: paths,
            typeFilter: typeFilter,
            namePattern: namePattern,
            includeHidden: includeHidden,
            maxFileSize: maxFileSize,
            readText: readText,
            readBinary: readBinary,
            exclude: exclude,
            onBatch: onBatch,
            onComplete: onComplete
        )
    }
}

/// Scans the standard application directories (Launchpad-style).
struct AppSource: ItemSource {
    func load(onBatch: @escaping @MainActor ([SearchableItem]) -> Void,
              onComplete: @escaping @MainActor () -> Void) {
        FileIndexer.enumerate(
            paths: standardAppPaths(),
            typeFilter: TypeFilter(extensions: [], categories: [.app]),
            namePattern: nil,
            includeHidden: false,
            onBatch: onBatch,
            onComplete: onComplete
        )
    }
}

/// Streams candidate files from the index daemon over its socket instead of
/// walking the filesystem. Used by a plain `mff` run when a daemon is up and
/// indexing is enabled; the daemon already narrowed to the query, and the GUI
/// re-scores the returned paths exactly as for a live walk.
///
/// With an empty query the daemon returns every indexed path (optionally
/// restricted to `prefix`), so the initial list matches a plain walk.
struct IndexSource: ItemSource {
    let query: String
    /// Restrict results to these subtrees (`-p/--path` in index mode); empty
    /// means the whole index.
    let prefixes: [String]
    /// Search-time exclude patterns (`exclude` in config + `--exclude`).
    let excludes: [String]
    /// In content mode the daemon also matches indexed binary content.
    let content: Bool
    let typeFilter: TypeFilter
    let namePattern: String?

    func load(onBatch: @escaping @MainActor ([SearchableItem]) -> Void,
              onComplete: @escaping @MainActor () -> Void) {
        let client = IndexClient()
        let typeFilter = self.typeFilter
        let loweredName = namePattern?.lowercased()
        let prefixes = self.prefixes
        let excludes = self.excludes
        let content = self.content
        let excludeMatcher = excludes.isEmpty ? nil : ExcludeMatcher(patterns: excludes)
        DispatchQueue.global(qos: .userInitiated).async {
            let started = client.search(
                query: query,
                prefixes: prefixes,
                excludes: excludes,
                content: content,
                onBatch: { hits in
                    let items = hits.compactMap { hit -> SearchableItem? in
                        // The daemon already filters, but filter here too so a
                        // stale daemon (or a direct client) cannot leak paths.
                        if let excludeMatcher, excludeMatcher.matches(hit.path) { return nil }
                        // No `URL` here (see `SearchableItem(indexPath:)`): broad
                        // queries produce tens of thousands of hits and a `URL`
                        // per hit dominates the rest of the item's cost.
                        let isDir = hit.isDirectory
                        let name = hit.name
                        if let loweredName,
                           !name.lowercased().contains(loweredName) { return nil }
                        if !typeFilter.isEmpty,
                           !typeFilter.matches(path: hit.path, ext: hit.fileExtension,
                                               isDirectory: isDir) {
                            return nil
                        }
                        // Audio metadata from the index becomes the item's
                        // `binaryText` (matched by --binary); binary files carry
                        // the index's binary flag.
                        return SearchableItem(indexPath: hit.path, isDirectory: isDir,
                                              binaryText: hit.binaryText,
                                              indexBinary: hit.isBinary)
                    }
                    guard !items.isEmpty else { return }
                    DispatchQueue.main.async { onBatch(items) }
                },
                onComplete: { total, partial in
                    DispatchQueue.main.async {
                        // No usable results and some volume was not ready: fall
                        // back to a live walk so the user never sees an empty
                        // list because the index was incomplete.
                        if total == 0, partial {
                            self.walkFallback(onBatch: onBatch, onComplete: onComplete)
                        } else {
                            onComplete()
                        }
                    }
                })
            if !started {
                // Daemon vanished mid-run: walk live.
                DispatchQueue.main.async {
                    self.walkFallback(onBatch: onBatch, onComplete: onComplete)
                }
            }
        }
    }

    /// Live filesystem walk used when the daemon is unreachable/incomplete.
    private func walkFallback(onBatch: @escaping @MainActor ([SearchableItem]) -> Void,
                              onComplete: @escaping @MainActor () -> Void) {
        let paths = prefixes.isEmpty ? [FileManager.default.currentDirectoryPath] : prefixes
        FileIndexer.enumerate(paths: paths,
                              typeFilter: typeFilter,
                              namePattern: namePattern,
                              includeHidden: false,
                              exclude: excludes,
                              onBatch: onBatch,
                              onComplete: onComplete)
    }
}

// MARK: - Shared helpers

func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

/// Standard locations Launchpad-like tools search for applications.
func standardAppPaths() -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    // Note: Utilities subfolders are covered by the recursive scan of their
    // parents, so we deliberately do not list them separately (avoids dupes).
    let candidates = [
        "/Applications",
        "/System/Applications",
        "/System/Library/CoreServices/Applications",
        home + "/Applications"
    ]
    let existing = candidates.filter { isDirectory($0) }
    return existing.isEmpty ? ["/Applications"] : existing
}
