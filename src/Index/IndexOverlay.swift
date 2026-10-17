import Foundation

// MARK: - Incremental index overlay

/// One indexed entry, independent of where it lives (base index or overlay).
struct IndexEntry {
    let path: String
    let isDirectory: Bool
    let isBinary: Bool
    let binaryText: String?
}

/// Mutable top layer over the immutable base `FileIndex`, per agent.md 3.7:
/// FSEvents updates change only a few directories, so instead of rebuilding we
/// keep the base as-is plus a small overlay of added/changed entries and a
/// `dead` set of removed paths. Search consults base (minus dead) then overlay.
///
/// When the overlay grows past `compactThreshold`, the daemon folds it back
/// into a fresh base (a full rebuild) and clears the overlay.
final class IndexOverlay {
    /// New or changed entries, keyed by path.
    private var added: [String: IndexEntry] = [:]
    /// Paths removed since the base was built (base entries to skip).
    private var dead: Set<String> = []

    /// Overlay size that should trigger a full rebuild.
    static let compactThreshold = 50_000

    var addedCount: Int { added.count }
    var deadCount: Int { dead.count }
    /// Adds or replaces one entry (clears any tombstone for the same path).
    func upsert(_ entry: IndexEntry) {
        dead.remove(entry.path)
        added[entry.path] = entry
    }

    /// Marks a path as removed. A path that was only in the overlay is dropped
    /// outright; a base path gets a tombstone.
    func remove(_ path: String) {
        added.removeValue(forKey: path)
        dead.insert(path)
    }

    /// Removes everything under a directory prefix (used when a directory is
    /// deleted; FSEvents reports the directory, not each descendant).
    func removeSubtree(_ dirPath: String) {
        let prefix = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
        for key in added.keys where key == dirPath || key.hasPrefix(prefix) {
            added.removeValue(forKey: key)
        }
        dead.insert(dirPath)
        // We cannot tombstone unknown descendants cheaply, so leave that to the
        // next compaction; searches additionally skip paths whose ancestor is
        // dead (see IndexOverlay.isUnderDead).
        deadSubtrees.insert(dirPath)
    }

    /// Directory subtrees known to be gone; any descendant path is treated dead.
    private var deadSubtrees: Set<String> = []

    /// True if `path` is dead itself or lives under a dead subtree.
    func isUnderDead(_ path: String) -> Bool {
        if dead.contains(path) { return true }
        for dir in deadSubtrees {
            let prefix = dir.hasSuffix("/") ? dir : dir + "/"
            if path.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// All added entries (for the search pass that runs after the base).
    func allAdded() -> [IndexEntry] { Array(added.values) }

    /// True when the overlay has grown enough to warrant folding into the base.
    func shouldCompact() -> Bool {
        added.count + dead.count * 4 >= Self.compactThreshold
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        struct Item: Codable { var path: String; var isDir: Bool; var isBinary: Bool; var text: String? }
        var added: [Item]
        var dead: [String]
        var deadSubtrees: [String]
    }

    /// Serializes the overlay so incremental changes survive a daemon restart.
    func save(to url: URL) {
        let snap = Snapshot(
            added: added.values.map { Snapshot.Item(path: $0.path, isDir: $0.isDirectory,
                                                    isBinary: $0.isBinary, text: $0.binaryText) },
            dead: Array(dead),
            deadSubtrees: Array(deadSubtrees))
        guard let data = try? JSONEncoder().encode(snap) else { return }
        AtomicFile.write(data, to: url)
    }

    /// Restores an overlay. Returns false if the file is missing/unreadable.
    @discardableResult
    func load(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return false }
        added.removeAll()
        dead.removeAll()
        deadSubtrees.removeAll()
        for it in snap.added {
            added[it.path] = IndexEntry(path: it.path, isDirectory: it.isDir,
                                        isBinary: it.isBinary, binaryText: it.text)
        }
        dead = Set(snap.dead)
        deadSubtrees = Set(snap.deadSubtrees)
        return true
    }

    func reset() {
        added.removeAll()
        dead.removeAll()
        deadSubtrees.removeAll()
    }
}

// MARK: - FileIndex enumeration

extension FileIndex {
    /// Materializes every entry as an `IndexEntry`. Used to seed the overlay's
    /// base view and to fold an overlay back into a fresh base.
    func allEntries() -> [IndexEntry] {
        var out: [IndexEntry] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let binary = binaryContent(at: i)
            out.append(IndexEntry(
                path: path(at: i),
                isDirectory: isDirectory(at: i),
                isBinary: isBinary(at: i),
                binaryText: binary.text
            ))
        }
        return out
    }
}
