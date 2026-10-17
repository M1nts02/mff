import Foundation

/// Extracts an embedded cover image from a Matroska (.mkv) / WebM file.
///
/// Only the container's `Attachments` element is read — the canonical place
/// where muxers such as mkvmerge store `cover.jpg`. No video frame is decoded,
/// and elements are skipped by seeking, so it stays cheap on large files.
enum MatroskaCover {
    /// Returns the raw image bytes of the first image attachment, if any.
    static func read(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let reader = MatroskaReader(handle)

        // EBML header: skip it entirely.
        guard reader.readID() == idEBML, let headerSize = reader.readSize() else { return nil }
        reader.skip(headerSize)

        // Segment: walk its top-level children. Attachments usually come before
        // the first Cluster, but we seek past every element so ordering is free.
        guard reader.readID() == idSegment else { return nil }
        let segmentEnd = reader.readSize().map { reader.offset + $0 }

        var steps = 0
        while steps < 4096 {
            if let segmentEnd, reader.offset >= segmentEnd { break }
            steps += 1

            guard let id = reader.readID(), let size = reader.readSize() else { break }
            let dataStart = reader.offset

            if id == idAttachments, let cover = readAttachments(reader, size: size) {
                return cover
            }
            reader.seek(to: dataStart + size)
        }
        return nil
    }
}

// MARK: - Element IDs

private extension MatroskaCover {
    static let idEBML: UInt64 = 0x1A45_DFA3
    static let idSegment: UInt64 = 0x1853_8067
    static let idAttachments: UInt64 = 0x1941_A469
    static let idAttachedFile: UInt64 = 0x61A7
    static let idFileName: UInt64 = 0x466E
    static let idFileMimeType: UInt64 = 0x4660
    static let idFileData: UInt64 = 0x465C
    /// Refuse absurd attachment payloads (a corrupt length must not blow up RAM).
    static let maxImageSize: UInt64 = 64 * 1024 * 1024

    static func readAttachments(_ reader: MatroskaReader, size: UInt64) -> Data? {
        let end = reader.offset + size
        while reader.offset < end {
            guard let id = reader.readID(), let childSize = reader.readSize() else { return nil }
            let dataStart = reader.offset

            if id == idAttachedFile, let cover = readAttachedFile(reader, size: childSize) {
                return cover
            }
            reader.seek(to: dataStart + childSize)
        }
        return nil
    }

    static func readAttachedFile(_ reader: MatroskaReader, size: UInt64) -> Data? {
        let end = reader.offset + size
        var fileName: String?
        var mimeType: String?
        var imageData: Data?

        while reader.offset < end {
            guard let id = reader.readID(), let childSize = reader.readSize() else { return nil }
            let dataStart = reader.offset

            switch id {
            case idFileName:
                fileName = reader.readString(childSize)
            case idFileMimeType:
                mimeType = reader.readString(childSize)
            case idFileData:
                imageData = childSize <= maxImageSize ? reader.readData(childSize) : nil
            default:
                break
            }
            reader.seek(to: dataStart + childSize)
        }

        guard let imageData, isImage(fileName: fileName, mimeType: mimeType) else { return nil }
        return imageData
    }

    static func isImage(fileName: String?, mimeType: String?) -> Bool {
        if let mimeType = mimeType?.lowercased(), mimeType.hasPrefix("image/") {
            return true
        }
        guard let name = fileName?.lowercased() else { return false }
        return name.hasSuffix(".jpg") || name.hasSuffix(".jpeg")
            || name.hasSuffix(".png") || name.hasSuffix(".webp")
    }
}
