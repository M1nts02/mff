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

/// Reads newline-separated items from stdin (fzf-style).
struct StdinSource: ItemSource {
    func load(onBatch: @escaping @MainActor ([SearchableItem]) -> Void,
              onComplete: @escaping @MainActor () -> Void) {
        if isatty(FileHandle.standardInput.fileDescriptor) != 0 {
            fputs("mff: no input. Pipe items on stdin, or pass a path/type to search files.\n", stderr)
            exit(1)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let handle = FileHandle.standardInput
            let chunkSize = 64 * 1024
            var pending = ""
            var batch: [String] = []
            batch.reserveCapacity(512)

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
                        if batch.count >= 512 {
                            let chunk = batch
                            batch.removeAll(keepingCapacity: true)
                            let items = chunk.map { SearchableItem(text: $0) }
                            DispatchQueue.main.async { onBatch(items) }
                        }
                    }
                }
                pending = text
            }

            if !pending.isEmpty { batch.append(pending) }
            if !batch.isEmpty {
                let chunk = batch
                let items = chunk.map { SearchableItem(text: $0) }
                DispatchQueue.main.async { onBatch(items) }
            }
            DispatchQueue.main.async { onComplete() }
        }
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
