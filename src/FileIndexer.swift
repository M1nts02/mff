import Foundation

/// Lazily walks directory trees and reports files in batches on the main queue,
/// so the UI can stream results the way fzf streams stdin.
enum FileIndexer {

    static func enumerate(
        paths: [String],
        typeFilter: TypeFilter,
        namePattern: String?,
        includeHidden: Bool,
        onBatch: @escaping @MainActor ([SearchableItem]) -> Void,
        onComplete: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey
            ]
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !includeHidden {
                options.insert(.skipsHiddenFiles)
            }

            let loweredName = namePattern?.lowercased()
            var batch: [SearchableItem] = []
            batch.reserveCapacity(256)

            for path in paths {
                let url = URL(fileURLWithPath: path)
                guard let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(keys),
                    options: options
                ) else { continue }

                while let fileURL = enumerator.nextObject() as? URL {
                    guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }

                    let isDir = values.isDirectory ?? false
                    let isSymlink = values.isSymbolicLink ?? false

                    // Avoid symlink loops while still allowing symlinked files.
                    if isDir && isSymlink { continue }

                    if let loweredName {
                        let name = fileURL.lastPathComponent.lowercased()
                        if !name.contains(loweredName) { continue }
                    }

                    if !typeFilter.matches(url: fileURL,
                                            ext: fileURL.pathExtension,
                                            isDirectory: isDir) {
                        continue
                    }

                    batch.append(SearchableItem(url: fileURL, isDirectory: isDir))

                    if batch.count >= 256 {
                        let chunk = batch
                        batch.removeAll(keepingCapacity: true)
                        DispatchQueue.main.async {
                            onBatch(chunk)
                        }
                    }
                }
            }

            if !batch.isEmpty {
                let chunk = batch
                DispatchQueue.main.async {
                    onBatch(chunk)
                }
            }

            DispatchQueue.main.async {
                onComplete()
            }
        }
    }
}
