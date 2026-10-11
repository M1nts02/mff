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

    func load(onBatch: @escaping @MainActor ([SearchableItem]) -> Void,
              onComplete: @escaping @MainActor () -> Void) {
        if isatty(FileHandle.standardInput.fileDescriptor) != 0 {
            fputs("mff: no input. Pipe items on stdin, or pass a path/type to search files.\n", stderr)
            exit(1)
        }

        let kind = self.kind
        let typeFilter = self.typeFilter
        let loweredName = namePattern?.lowercased()

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
                        return StdinSource.fileItem(
                            for: line,
                            typeFilter: typeFilter,
                            loweredName: loweredName
                        )
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
    private static func fileItem(for line: String,
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
           !typeFilter.matches(url: url, ext: url.pathExtension, isDirectory: isDir) {
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

    func load(onBatch: @escaping @MainActor ([SearchableItem]) -> Void,
              onComplete: @escaping @MainActor () -> Void) {
        FileIndexer.enumerate(
            paths: paths,
            typeFilter: typeFilter,
            namePattern: namePattern,
            includeHidden: includeHidden,
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

    func load(onBatch: @escaping @MainActor ([SearchableItem]) -> Void,
              onComplete: @escaping @MainActor () -> Void) {
        ContentIndexer.enumerate(
            paths: paths,
            typeFilter: typeFilter,
            namePattern: namePattern,
            includeHidden: includeHidden,
            maxFileSize: maxFileSize,
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
