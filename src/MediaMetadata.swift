import Foundation
import AVFoundation

/// Builds the searchable text blob for media files in grep mode.
///
/// Only audio metadata is matched, and only its title / artist / album. Video
/// and images (and everything else) are matched by name/path only.
enum MediaMetadata {

    /// Soft cap so a metadata-heavy file cannot blow up the index.
    private static let maxLength = 64 * 1024

    /// Returns the searchable metadata text for the given category, or nil when
    /// there is none (only audio has searchable metadata).
    static func searchableText(for url: URL, category: FileCategory) -> String? {
        guard category == .audio else { return nil }

        var parts: [String] = []

        // FLAC / Ogg tags are parsed natively (AVFoundation does not expose
        // their comments).
        if let parsed = AudioMetadata.read(url) {
            if let title = parsed.title { parts.append(title) }
            if let artist = parsed.artist { parts.append(artist) }
            if let album = parsed.album { parts.append(album) }
        }

        for item in AVURLAsset(url: url).commonMetadata {
            guard let commonKey = item.commonKey?.rawValue,
                  allowedAudioKeys.contains(commonKey) else { continue }
            if let value = item.stringValue, !value.isEmpty { parts.append(value) }
        }

        let text = parts.filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return text.count > maxLength ? String(text.prefix(maxLength)) : text
    }

    /// The only AV common keys we keep for audio.
    private static let allowedAudioKeys: Set<String> = [
        AVMetadataKey.commonKeyTitle.rawValue,
        AVMetadataKey.commonKeyArtist.rawValue,
        AVMetadataKey.commonKeyAlbumName.rawValue
    ]
}
