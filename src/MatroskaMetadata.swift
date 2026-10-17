import Foundation

// MARK: - Matroska / WebM metadata

/// Reads tags from a Matroska (.mkv) or WebM file: the `Info` title, the
/// `Tags` title/artist, and the writing app. Only element headers are walked
/// (payloads are seeked past), so it stays cheap even on large files.
/// Everything is bounds-checked.
struct MatroskaMetadata {
    var title: String?
    var artist: String?
    var encoder: String?
    var date: String?

    var isEmpty: Bool {
        title == nil && artist == nil && encoder == nil && date == nil
    }

    /// Parses `url`, or returns nil if it is not a Matroska/WebM file.
    static func read(_ url: URL) -> MatroskaMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let reader = MatroskaReader(handle)

        // EBML header.
        guard reader.readID() == idEBML, let headerSize = reader.readSize() else { return nil }
        reader.skip(headerSize)

        // Segment: walk its top-level children.
        guard reader.readID() == idSegment else { return nil }
        let segmentEnd = reader.readSize().map { reader.offset + $0 }

        var meta = MatroskaMetadata()
        var steps = 0
        while steps < 8192 {
            if let segmentEnd, reader.offset >= segmentEnd { break }
            steps += 1
            guard let id = reader.readID(), let size = reader.readSize() else { break }
            let dataStart = reader.offset

            switch id {
            case idInfo:
                parseInfo(reader, size: size, into: &meta)
            case idTags:
                parseTags(reader, size: size, into: &meta)
            default:
                break
            }
            reader.seek(to: dataStart + size)
        }
        return meta
    }

    // MARK: - Info

    private static func parseInfo(_ reader: MatroskaReader, size: UInt64, into meta: inout MatroskaMetadata) {
        let end = reader.offset + size
        while reader.offset < end {
            guard let id = reader.readID(), let childSize = reader.readSize() else { return }
            let dataStart = reader.offset
            switch id {
            case idTitle:
                if let s = reader.readString(childSize), !s.isEmpty { meta.title = s }
            case idDateUTC:
                // 8-byte signed nanoseconds since 2001-01-01; store as a readable date.
                if childSize == 8, let raw = reader.readUInt(8) {
                    let seconds = Double(Int64(bitPattern: raw)) / 1e9
                    let date = Date(timeIntervalSince1970: seconds + 978307200) // 2001-01-01 UTC
                    let fmt = DateFormatter()
                    fmt.dateFormat = "yyyy-MM-dd"
                    fmt.timeZone = TimeZone(identifier: "UTC")
                    meta.date = fmt.string(from: date)
                }
            case idMuxingApp, idWritingApp:
                if let s = reader.readString(childSize), !s.isEmpty, meta.encoder == nil {
                    meta.encoder = s
                }
            default:
                break
            }
            reader.seek(to: dataStart + childSize)
        }
    }

    // MARK: - Tags

    private static func parseTags(_ reader: MatroskaReader, size: UInt64, into meta: inout MatroskaMetadata) {
        let end = reader.offset + size
        while reader.offset < end {
            guard let id = reader.readID(), let childSize = reader.readSize() else { return }
            let dataStart = reader.offset
            if id == idTag {
                parseTag(reader, size: childSize, into: &meta)
            }
            reader.seek(to: dataStart + childSize)
        }
    }

    /// A `Tag` holds `SimpleTag` children; each has a `TagName` and a
    /// `TagString`. Handles one level of nesting (targets are ignored).
    private static func parseTag(_ reader: MatroskaReader, size: UInt64, into meta: inout MatroskaMetadata) {
        let end = reader.offset + size
        while reader.offset < end {
            guard let id = reader.readID(), let childSize = reader.readSize() else { return }
            let dataStart = reader.offset
            if id == idSimpleTag {
                parseSimpleTag(reader, size: childSize, into: &meta)
            }
            reader.seek(to: dataStart + childSize)
        }
    }

    private static func parseSimpleTag(_ reader: MatroskaReader, size: UInt64, into meta: inout MatroskaMetadata) {
        let end = reader.offset + size
        var name: String?
        var value: String?
        while reader.offset < end {
            guard let id = reader.readID(), let childSize = reader.readSize() else { return }
            let dataStart = reader.offset
            if id == idTagName {
                name = reader.readString(childSize)?.lowercased()
            } else if id == idTagString {
                value = reader.readString(childSize)
            }
            reader.seek(to: dataStart + childSize)
        }
        guard let name, let value, !value.isEmpty else { return }
        switch name {
        case "title": meta.title = value
        case "artist", "album_artist", "albumartist": meta.artist = value
        case "encoder": meta.encoder = value
        case "date", "date_released", "date_recorded": meta.date = value
        default: break
        }
    }
}

// MARK: - Element IDs

private extension MatroskaMetadata {
    static let idEBML: UInt64 = 0x1A45_DFA3
    static let idSegment: UInt64 = 0x1853_8067
    static let idInfo: UInt64 = 0x1549_A966
    static let idTitle: UInt64 = 0x7BA9
    static let idDateUTC: UInt64 = 0x4461
    static let idMuxingApp: UInt64 = 0x4D80
    static let idWritingApp: UInt64 = 0x5741
    static let idTags: UInt64 = 0x1254_C367
    static let idTag: UInt64 = 0x7373
    static let idSimpleTag: UInt64 = 0x67C8
    static let idTagName: UInt64 = 0x45A3
    static let idTagString: UInt64 = 0x4487
}
