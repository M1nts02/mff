import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import PDFKit

/// Builds the searchable text blob for **binary files** in `--binary` content
/// mode. One extractor per file category; the category decides which metadata
/// is worth indexing: audio (title/artist/album), images (camera model +
/// capture date), video (container title/artist/description), and PDF (title /
/// author / subject / keywords / creator / producer).
enum MediaMetadata {

    /// Soft cap so a metadata-heavy file cannot blow up the index.
    private static let maxLength = 64 * 1024

    /// Files larger than this are not opened by AVFoundation / PDFKit for
    /// metadata: on slow external disks, opening a multi-hundred-MB media file
    /// just to read tags costs seconds. Native (header-only) parsers are still
    /// used regardless of size because they read a few KB.
    private static let avMetadataSizeLimit: Int = 8 * 1024 * 1024
    private static let pdfSizeLimit: Int = 8 * 1024 * 1024
    private static let imageMetadataSizeLimit: Int = 24 * 1024 * 1024
    /// Matroska tags require seeking across the file; skip large videos.
    private static let matroskaSizeLimit: Int = 64 * 1024 * 1024
    /// FLAC/Ogg tag blocks live at the start, but a huge file's cover/seeks are
    /// still costly on slow disks; skip tag parsing for very large audio.
    private static let audioNativeSizeLimit: Int = 128 * 1024 * 1024

    /// Image formats that may carry camera EXIF worth indexing. PNG/GIF/WebP/
    /// SVG/BMP are skipped: opening them with ImageIO reads the whole file and
    /// they almost never have camera metadata, so they would dominate an index.
    private static let exifImageExtensions: Set<String> = [
        "jpg", "jpeg", "tif", "tiff", "heic", "heif", "dng", "cr2", "cr3",
        "nef", "arw", "raf", "orf", "rw2"
    ]

    /// Returns the searchable binary-content text for the given category, or nil
    /// when there is none.
    static func searchableText(for url: URL, category: FileCategory, fileSize: Int? = nil) -> String? {
        // Cheap dispatch: non-media categories never have metadata, so return
        // before touching the file.
        switch category {
        case .audio, .image, .video: break
        case .document where url.pathExtension.lowercased() == "pdf": break
        default: return nil
        }

        // Matroska (.mkv) / WebM: tags live near the end of the Segment, so the
        // parser seeks across the whole file. On a large file over a slow disk
        // that costs tens of seconds, so only attempt it for small files.
        let ext = url.pathExtension.lowercased()
        let sizeHint = fileSize ?? size(of: url)
        if ext == "mkv" || ext == "webm", (sizeHint ?? 0) <= matroskaSizeLimit,
           let meta = MatroskaMetadata.read(url), !meta.isEmpty {
            return clamp([meta.title, meta.artist, meta.encoder, meta.date].compactMap { $0 })
        }

        let parts: [String]
        switch category {
        case .audio: parts = audioText(url, size: sizeHint)
        case .image: parts = imageText(url, size: sizeHint)
        case .video: parts = videoText(url, size: sizeHint)
        case .document: parts = pdfText(url, size: sizeHint)
        default: return nil
        }
        return clamp(parts)
    }

    /// Whether metadata extraction might apply to this extension. Kept cheap so
    /// the index build can skip the size lookup for everything else.
    static func hasExtractableMetadata(ext: String) -> Bool {
        let e = ext.lowercased()
        switch e {
        case "pdf", "mkv", "webm": return true
        default:
            let cat = FileTypeRegistry.category(for: e)
            if cat == .audio || cat == .video { return true }
            if cat == .image { return exifImageExtensions.contains(e) }
            return false
        }
    }

    /// File size in bytes, or nil when it cannot be read.
    private static func size(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    /// Reads up to `maxBytes` from the start of the file, or nil on failure.
    private static func readHeader(_ url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: maxBytes)) ?? nil
    }

    /// Joins non-empty parts, caps the length, and returns nil when empty.
    private static func clamp(_ parts: [String]) -> String? {
        let text = parts.filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return text.count > maxLength ? String(text.prefix(maxLength)) : text
    }

    // MARK: - Audio

    /// Audio: title / artist / album.
    private static func audioText(_ url: URL, size fileSize: Int?) -> [String] {
        var parts: [String] = []
        // FLAC / Ogg tags are parsed natively (header only — cheap on any disk).
        // Indexing never needs the cover art; skipping it avoids reading
        // multi-MB picture blocks from slow disks. Large files are skipped
        // entirely: their tag blocks are far away and seeking is costly.
        if let fileSize, fileSize > audioNativeSizeLimit { return [] }
        if let parsed = AudioMetadata.read(url, wantArtwork: false) {
            if let title = parsed.title { parts.append(title) }
            if let artist = parsed.artist { parts.append(artist) }
            if let album = parsed.album { parts.append(album) }
        }
        // AVFoundation opens the whole file; skip it for large files on slow
        // disks. Native tags above already cover FLAC/Ogg.
        if let fileSize, fileSize > avMetadataSizeLimit { return parts }
        for item in AVURLAsset(url: url).commonMetadata {
            guard let key = item.commonKey?.rawValue, audioKeys.contains(key) else { continue }
            if let value = item.stringValue, !value.isEmpty { parts.append(value) }
        }
        return parts
    }

    private static let audioKeys: Set<String> = [
        AVMetadataKey.commonKeyTitle.rawValue,
        AVMetadataKey.commonKeyArtist.rawValue,
        AVMetadataKey.commonKeyAlbumName.rawValue
    ]

    // MARK: - Image

    /// Image: camera model + capture date (minimal, via ImageIO / EXIF).
    private static func imageText(_ url: URL, size fileSize: Int?) -> [String] {
        // ImageIO maps/reads the file to build a source; on slow disks a huge
        // image (RAW, PSD, AI) costs a lot just to read EXIF. Skip big ones.
        guard Self.exifImageExtensions.contains(url.pathExtension.lowercased()) else { return [] }
        if let fileSize, fileSize > imageMetadataSizeLimit { return [] }
        // Read just the header and parse EXIF from it: CGImageSourceCreateWithURL
        // reads the whole file, which is very slow for a large index on external
        // disks. EXIF lives near the start (JPEG APP1 / TIFF IFD).
        guard let head = Self.readHeader(url, maxBytes: 64 * 1024) else { return [] }
        guard let source = CGImageSourceCreateWithData(head as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            // Header-only parse failed (e.g. EXIF beyond the window); give up
            // rather than falling back to reading the whole file.
            return []
        }
        var parts: [String] = []

        // EXIF: camera make + model, and the original capture date.
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String { parts.append(date) }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let make = tiff[kCGImagePropertyTIFFMake] as? String { parts.append(make) }
            if let model = tiff[kCGImagePropertyTIFFModel] as? String { parts.append(model) }
        }
        return parts
    }

    // MARK: - Video

    /// Video: container metadata via AVFoundation — title / artist / description
    /// (and the encoder as a fallback). Matroska/WebM are handled earlier by the
    /// native parser instead.
    private static func videoText(_ url: URL, size fileSize: Int?) -> [String] {
        // AVFoundation opens the whole file; skip large files on slow disks.
        if let fileSize, fileSize > avMetadataSizeLimit { return [] }
        var parts: [String] = []
        for item in AVURLAsset(url: url).commonMetadata {
            guard let key = item.commonKey?.rawValue, videoKeys.contains(key) else { continue }
            if let value = item.stringValue, !value.isEmpty { parts.append(value) }
        }
        return parts
    }

    private static let videoKeys: Set<String> = [
        AVMetadataKey.commonKeyTitle.rawValue,
        AVMetadataKey.commonKeyArtist.rawValue,
        AVMetadataKey.commonKeyDescription.rawValue
    ]

    // MARK: - PDF

    /// PDF: document info dictionary — title / author / subject / keywords /
    /// creator / producer.
    private static func pdfText(_ url: URL, size fileSize: Int?) -> [String] {
        // Opening a huge PDF just for the Info dict is expensive on slow disks.
        if let fileSize, fileSize > pdfSizeLimit { return [] }
        var parts: [String] = []
        if let doc = PDFDocument(url: url), let attrs = doc.documentAttributes {
            let keys: [PDFDocumentAttribute] = [
                .titleAttribute, .authorAttribute, .subjectAttribute,
                .keywordsAttribute, .creatorAttribute, .producerAttribute
            ]
            for key in keys {
                if let value = attrs[key] as? String, !value.isEmpty {
                    parts.append(value)
                } else if let list = attrs[key] as? [String] {
                    parts.append(contentsOf: list.filter { !$0.isEmpty })
                }
            }
        }
        return parts
    }
}
