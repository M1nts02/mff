import Foundation

/// Filesystem path completion for the search-folder editor. Only directories
/// are ever returned, since the value being edited is always a search root.
enum PathCompleter {

    /// Directory completions for a partially typed path.
    ///
    /// - If the typed path is (or ends with) an existing directory, that
    ///   directory's subdirectories are listed, so the user can drill in.
    /// - Otherwise the last path component is treated as a prefix and matching
    ///   sibling directories are listed.
    ///
    /// Results keep the same `~`/relative form the user typed.
    static func directoryCompletions(for input: String, includeHidden: Bool) -> [String] {
        let fm = FileManager.default
        let text = input.isEmpty ? "~/" : input
        let expanded = (text as NSString).expandingTildeInPath

        var isDir: ObjCBool = false
        let expandedIsDirectory = fm.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue

        let scanDirectory: String
        let prefix: String
        let resultBase: String

        if expanded.hasSuffix("/") || expandedIsDirectory {
            scanDirectory = expanded
            prefix = ""
            resultBase = text.hasSuffix("/") ? text : text + "/"
        } else {
            let directory = (expanded as NSString).deletingLastPathComponent
            scanDirectory = directory.isEmpty ? "/" : directory
            prefix = (expanded as NSString).lastPathComponent
            let base = (text as NSString).deletingLastPathComponent
            resultBase = base.isEmpty ? "" : base + "/"
        }

        guard let entries = try? fm.contentsOfDirectory(atPath: scanDirectory) else { return [] }
        let loweredPrefix = prefix.lowercased()

        var results: [String] = []
        for name in entries {
            if !includeHidden && name.hasPrefix(".") { continue }
            guard name.lowercased().hasPrefix(loweredPrefix) else { continue }

            let full = (scanDirectory as NSString).appendingPathComponent(name)
            var entryIsDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &entryIsDir), entryIsDir.boolValue else { continue }
            results.append(resultBase + name + "/")
        }

        results.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return results
    }
}
