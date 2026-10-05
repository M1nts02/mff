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
    static let textExts: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml",
        "toml", "ini", "plist", "html", "htm", "css", "js", "ts", "jsx",
        "tsx", "swift", "m", "mm", "c", "h", "cpp", "hpp", "cs", "java",
        "kt", "kts", "py", "rb", "go", "rs", "php", "sh", "zsh", "bash",
        "fish", "sql", "log", "conf", "cfg", "gitignore", "rst", "tex"
    ]
    static let archiveExts: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar",
        "dmg", "pkg", "iso", "deb", "rpm", "zst", "lz", "lz4"
    ]
    static let appExts: Set<String> = ["app", "bundle", "framework", "xcodeproj", "playground"]

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
            let lowerPath = url.path.lowercased()
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
    }

    init(url: URL, isDirectory: Bool) {
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

    func icon(for item: SearchableItem) -> NSImage? {
        guard let url = item.url else { return nil }
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
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return isDirectory
            ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(for: .data)
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
