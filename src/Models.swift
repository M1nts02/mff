import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - File categories (determined purely by extension)

enum FileCategory: String {
    case image
    case video
    case audio
    case document
    case text
    case archive
    case app
    case folder
    case other

    static func aliases(_ name: String) -> FileCategory? {
        switch name.lowercased() {
        case "image", "images", "picture", "pictures", "photo", "photos", "img":
            return .image
        case "video", "videos", "movie", "movies", "film", "films":
            return .video
        case "audio", "audios", "music", "sound", "sounds":
            return .audio
        case "document", "documents", "doc", "docs":
            return .document
        case "text", "texts", "txt":
            return .text
        case "archive", "archives", "compressed":
            return .archive
        case "app", "application", "applications", "apps":
            return .app
        case "folder", "folders", "directory", "directories", "dir":
            return .folder
        default:
            return nil
        }
    }
}

enum FileTypeRegistry {
    static let imageExts: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif",
        "bmp", "svg", "ico", "raw", "cr2", "nef", "arw", "dng", "psd", "ai",
        "eps", "avif", "jp2", "jxl"
    ]
    static let videoExts: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "wmv", "mpg",
        "mpeg", "3gp", "mts", "m2ts", "ts", "ogv", "vob"
    ]
    static let audioExts: Set<String> = [
        "mp3", "wav", "aac", "m4a", "flac", "ogg", "wma", "aiff", "aif",
        "alac", "opus", "mid", "midi", "ape", "amr"
    ]
    static let documentExts: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages",
        "numbers", "key", "rtf", "odt", "ods", "odp", "epub", "mobi"
    ]
    /// Lyrics and subtitle formats: part of the text category, and previewed as
    /// plain text because Quick Look often has no generator for them.
    static let lyricsSubtitleExts: Set<String> = [
        "lrc", "krc", "qrc",
        "srt", "ass", "ssa", "vtt", "sub", "sbv", "smi", "sami",
        "ttml", "dfxp", "scc"
    ]

    static let textExts: Set<String> = Set([
        "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml",
        "toml", "ini", "plist", "html", "htm", "css", "js", "ts", "jsx",
        "tsx", "swift", "m", "mm", "c", "h", "cpp", "hpp", "cs", "java",
        "kt", "kts", "py", "rb", "go", "rs", "php", "sh", "zsh", "bash",
        "fish", "sql", "log", "conf", "cfg", "gitignore", "rst", "tex",
        "lua"
    ]).union(lyricsSubtitleExts)
    static let archiveExts: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar",
        "dmg", "pkg", "iso", "deb", "rpm", "zst", "lz", "lz4"
    ]
    static let appExts: Set<String> = ["app", "bundle", "framework", "xcodeproj", "playground"]

    /// Extensions treated as binary by content search; the file is skipped
    /// without ever being read. Files with an unknown/empty extension are still
    /// probed by content (see ContentIndexer).
    static let binaryExts: Set<String> = imageExts
        .union(videoExts).union(audioExts).union(archiveExts)
        .union(documentExts).union(appExts)
        .union([
            "o", "a", "so", "dylib", "dll", "exe", "bin", "class", "pyc",
            "pyo", "wasm", "db", "sqlite", "sqlite3", "ttf", "otf", "woff",
            "woff2", "eot", "icns", "dat", "pak", "nib"
        ])

    static func isLikelyBinary(ext: String) -> Bool {
        binaryExts.contains(ext.lowercased())
    }

    static func category(for ext: String) -> FileCategory {
        let e = ext.lowercased()
        if imageExts.contains(e) { return .image }
        if videoExts.contains(e) { return .video }
        if audioExts.contains(e) { return .audio }
        if documentExts.contains(e) { return .document }
        if textExts.contains(e) { return .text }
        if archiveExts.contains(e) { return .archive }
        if appExts.contains(e) { return .app }
        return .other
    }
}

// MARK: - Type filter

struct TypeFilter {
    var extensions: Set<String> = []
    var categories: Set<FileCategory> = []

    var isEmpty: Bool { extensions.isEmpty && categories.isEmpty }

    func matches(url: URL, ext: String, isDirectory: Bool) -> Bool {
        matches(path: url.path, ext: ext, isDirectory: isDirectory)
    }

    /// Path-based form used on hot paths (index hits) where no `URL` exists.
    /// `ext` is the extension without the dot (any case).
    func matches(path: String, ext: String, isDirectory: Bool) -> Bool {
        if isEmpty { return true }
        let e = ext.lowercased()

        // Plain folders.
        if isDirectory && categories.contains(.folder) { return true }

        // Explicit extension filters (also applies to bundles such as .app).
        for token in extensions where token == e {
            return true
        }
        // multi-part extensions such as "tar.gz"
        if !extensions.isEmpty {
            let lowerPath = path.lowercased()
            for token in extensions where token.contains(".") {
                if lowerPath.hasSuffix("." + token) { return true }
            }
        }

        // Category filters by extension. Bundles (.app, .bundle, ...) are
        // directories, so this must not be short-circuited by isDirectory.
        if !e.isEmpty, categories.contains(FileTypeRegistry.category(for: e)) {
            return true
        }
        return false
    }
}

// MARK: - Searchable item

struct SearchableItem {
    let id: Int
    let raw: String            // full path (files) or the raw line (stdin)
    let displayName: String    // filename (files) or the raw line (stdin)
    let parentPath: String     // parent directory, empty for stdin items
    let url: URL?              // non-nil for files (enables Quick Look + icons)
    let isDirectory: Bool
    let lowerSearch: String    // lowercased full path (default search target)
    let lowerDisplay: String   // lowercased display name (default name search)
    let fileExtension: String  // lowercased extension without the dot ("" if none)
    /// Text contents for content-search mode (capped size); nil in every other
    /// mode so plain file search never pays for reading files. Only used when
    /// `--content` (text search) is on.
    let content: String?
    /// Binary-file content text (currently audio metadata) for `--binary`
    /// from the index when available, or is parsed live otherwise.
    let binaryText: String?
    /// Whether the file was classified binary at index time (content mode).
    /// When true, its text is never read for content matching.
    let indexBinary: Bool

    private static var idCounter = 0
    private static let idLock = NSLock()

    private static func nextID() -> Int {
        idLock.lock()
        defer { idLock.unlock() }
        let id = idCounter
        idCounter += 1
        return id
    }

    init(text: String) {
        self.id = Self.nextID()
        self.raw = text
        self.displayName = text
        self.parentPath = ""
        self.url = nil
        self.isDirectory = false
        self.lowerSearch = text.lowercased()
        self.lowerDisplay = self.lowerSearch
        self.fileExtension = ""
        self.content = nil
        self.binaryText = nil
        self.indexBinary = false
    }

    init(url: URL, isDirectory: Bool, content: String? = nil,
         binaryText: String? = nil, indexBinary: Bool = false) {
        self.id = Self.nextID()
        self.raw = url.path
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        self.displayName = name
        self.parentPath = url.deletingLastPathComponent().path
        self.url = url
        self.isDirectory = isDirectory
        self.lowerSearch = self.raw.lowercased()
        self.lowerDisplay = name.lowercased()
        self.fileExtension = url.pathExtension.lowercased()
        self.content = content
        self.binaryText = binaryText
        self.indexBinary = indexBinary
    }

    /// Builds an item straight from a path string, skipping `URL` entirely.
    /// Used by index hits: `String(describing: URL)` costs ~3x the rest of the
    /// item and `URL.fileURLWithPath` is only needed for Quick Look / icons,
    /// which `SearchableItem.resolvedURL` creates on demand.
    init(indexPath path: String, isDirectory: Bool, binaryText: String?,
         indexBinary: Bool, content: String? = nil) {
        self.id = Self.nextID()
        self.raw = path
        let name = (path as NSString).lastPathComponent
        self.displayName = name.isEmpty ? path : name
        self.parentPath = (path as NSString).deletingLastPathComponent
        self.url = nil
        self.isDirectory = isDirectory
        self.lowerSearch = path.lowercased()
        self.lowerDisplay = self.displayName.lowercased()
        self.fileExtension = (name as NSString).pathExtension.lowercased()
        self.content = content
        self.binaryText = binaryText
        self.indexBinary = indexBinary
    }

    /// The file URL, built on demand for items that were created from an index
    /// path without one. Hot paths (matching, filtering) use `raw` / lowercase
    /// fields and never touch this.
    var resolvedURL: URL? {
        url ?? (raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : nil)
    }

    /// A copy with `content` filled in. Used to attach text contents lazily
    /// during content matching when the item came from the index (which stores
    /// binary content but not text contents).
    func withContent(_ content: String?) -> SearchableItem {
        SearchableItem(id: id, raw: raw, displayName: displayName, parentPath: parentPath,
                       url: url, isDirectory: isDirectory, lowerSearch: lowerSearch,
                       lowerDisplay: lowerDisplay, fileExtension: fileExtension,
                       content: content, binaryText: binaryText, indexBinary: indexBinary)
    }

    /// A copy with `binaryText` filled in (lazy audio-metadata parse when the
    /// index did not supply it).
    func withBinaryText(_ binaryText: String?) -> SearchableItem {
        SearchableItem(id: id, raw: raw, displayName: displayName, parentPath: parentPath,
                       url: url, isDirectory: isDirectory, lowerSearch: lowerSearch,
                       lowerDisplay: lowerDisplay, fileExtension: fileExtension,
                       content: content, binaryText: binaryText, indexBinary: indexBinary)
    }

    private init(id: Int, raw: String, displayName: String, parentPath: String, url: URL?,
                 isDirectory: Bool, lowerSearch: String, lowerDisplay: String,
                 fileExtension: String, content: String?, binaryText: String?, indexBinary: Bool) {
        self.id = id
        self.raw = raw
        self.displayName = displayName
        self.parentPath = parentPath
        self.url = url
        self.isDirectory = isDirectory
        self.lowerSearch = lowerSearch
        self.lowerDisplay = lowerDisplay
        self.fileExtension = fileExtension
        self.content = content
        self.binaryText = binaryText
        self.indexBinary = indexBinary
    }
}

struct MatchResult {
    let item: SearchableItem
    let score: Int
    /// Matched character positions per search term, so each term can be
    /// highlighted in its own colour. Indices point into the match target.
    let termPositions: [[Int]]
}

// MARK: - Icon cache (extension-based icons)

final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    private let size: CGFloat = 20
    /// `[icons.overrides]` from config.toml: extension -> app name / bundle id /
    /// path whose icon to use instead of the file's own.
    var overrides: [String: String] = [:]

    func icon(for item: SearchableItem) -> NSImage? {
        guard let url = item.resolvedURL else { return nil }
        let ext = url.pathExtension.lowercased()
        // Application bundles get their real icon so --app looks like Launchpad.
        let isBundle = item.isDirectory && FileTypeRegistry.appExts.contains(ext)

        let key: String
        if isBundle {
            key = "bundle:" + url.path
        } else if item.isDirectory && ext.isEmpty {
            key = "folder"
        } else if !ext.isEmpty {
            key = "ext:" + ext
        } else {
            key = "file"
        }
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        let raw = isBundle
            ? NSWorkspace.shared.icon(forFile: url.path)
            : makeIcon(url: url, isDirectory: item.isDirectory, ext: ext)
        let image = resized(raw, to: size)
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    private func makeIcon(url: URL, isDirectory: Bool, ext: String) -> NSImage {
        // A configured override wins: the value may be an app name, a bundle
        // identifier, or an absolute path to an .app / icon source.
        if !ext.isEmpty, let override = overrides[ext] {
            if let image = overrideIcon(override) { return image }
        }
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return isDirectory
            ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(for: .data)
    }

    /// Resolves an override value to an icon: an absolute path (used directly),
    /// or an application looked up via Launch Services by name / bundle id.
    private func overrideIcon(_ value: String) -> NSImage? {
        if value.hasPrefix("/") {
            return NSWorkspace.shared.icon(forFile: value)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(forFile: "/Applications/\(value).app")
    }

    private func resized(_ image: NSImage, to size: CGFloat) -> NSImage {
        let new = NSImage(size: NSSize(width: size, height: size))
        new.lockFocus()
        if let copy = image.copy() as? NSImage {
            copy.size = NSSize(width: size, height: size)
            copy.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                      from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        new.unlockFocus()
        return new
    }
}
