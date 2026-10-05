import Foundation

/// Reads tag and cover-art metadata that AVFoundation does not expose natively,
/// currently FLAC and Ogg (Vorbis / Opus). Only the metadata headers at the
/// start of the file are parsed — never the audio frames — so it stays cheap
/// even for large files.
struct AudioMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var artwork: Data?

    var isEmpty: Bool {
        title == nil && artist == nil && album == nil && artwork == nil
    }

    /// Returns `nil` when the container is unsupported or holds no metadata.
    static func read(_ url: URL) -> AudioMetadata? {
        switch url.pathExtension.lowercased() {
        case "flac":
            return readFLAC(url)
        case "ogg", "oga", "opus":
            return readOgg(url)
        default:
            return nil
        }
    }
}

// MARK: - FLAC

private extension AudioMetadata {
    /// Refuse absurd metadata blocks (a malformed length would otherwise make
    /// us read a huge amount of data into memory).
    static let maxBlockSize = 64 * 1024 * 1024

    static func readFLAC(_ url: URL) -> AudioMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard handle.readData(ofLength: 4) == Data("fLaC".utf8) else { return nil }

        var metadata = AudioMetadata()

        // Metadata blocks: 1 byte (last-block flag + block type) + 3-byte
        // big-endian length, immediately after the "fLaC" marker.
        while true {
            let header = handle.readData(ofLength: 4)
            guard header.count == 4 else { break }

            let isLast = header[header.startIndex] & 0x80 != 0
            let type = header[header.startIndex] & 0x7F
            let length = Int(header[header.startIndex + 1]) << 16
                | Int(header[header.startIndex + 2]) << 8
                | Int(header[header.startIndex + 3])

            if (type == 4 || type == 6), length > 0, length <= maxBlockSize {
                let block = handle.readData(ofLength: length)
                guard block.count == length else { break }
                if type == 4 {
                    parseVorbisComments(block, into: &metadata)
                } else {
                    metadata.artwork = pictureImageData(block)
                }
            } else if length > 0 {
                handle.seek(toFileOffset: handle.offsetInFile + UInt64(length))
            }

            if isLast { break }
        }

        return metadata.isEmpty ? nil : metadata
    }
}

// MARK: - Ogg (Vorbis / Opus)

private extension AudioMetadata {
    static func readOgg(_ url: URL) -> AudioMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Collect the first two packets of the first logical stream. For both
        // Vorbis and Opus the second packet is the comment header.
        var packets: [Data] = []
        var current = Data()

        while packets.count < 2 {
            let header = handle.readData(ofLength: 27)
            guard header.count == 27, header.starts(with: Data("OggS".utf8)) else { break }

            let segmentCount = Int(header[header.startIndex + 26])
            let segmentTable = handle.readData(ofLength: segmentCount)
            guard segmentTable.count == segmentCount else { break }

            let payloadLength = segmentTable.reduce(0) { $0 + Int($1) }
            let payload = handle.readData(ofLength: payloadLength)
            guard payload.count == payloadLength else { break }

            var offset = payload.startIndex
            for segment in segmentTable {
                let length = Int(segment)
                current.append(contentsOf: payload[offset..<(offset + length)])
                offset += length
                // A segment shorter than 255 bytes terminates the packet.
                if length < 255 {
                    packets.append(current)
                    current = Data()
                    if packets.count >= 2 { break }
                }
            }
        }

        guard packets.count >= 2 else { return nil }
        let commentHeader = packets[1]

        var metadata = AudioMetadata()
        let vorbisMagic: [UInt8] = [0x03] + Array("vorbis".utf8)
        if commentHeader.starts(with: vorbisMagic) {
            parseVorbisComments(commentHeader.dropFirst(vorbisMagic.count), into: &metadata)
        } else if commentHeader.starts(with: Data("OpusTags".utf8)) {
            parseVorbisComments(commentHeader.dropFirst(8), into: &metadata)
        } else {
            return nil
        }

        return metadata.isEmpty ? nil : metadata
    }
}

// MARK: - Vorbis comment / picture parsing

private extension AudioMetadata {
    /// Parses a Vorbis comment block (little-endian). Used by FLAC directly and
    /// by Ogg after the codec-specific header prefix.
    static func parseVorbisComments<S: DataProtocol>(_ data: S, into metadata: inout AudioMetadata) {
        var reader = ByteReader(data)
        guard let vendorLength = reader.uint32LE(), reader.skip(Int(vendorLength)),
              let count = reader.uint32LE() else { return }

        for _ in 0..<count {
            guard let length = reader.uint32LE(), let entry = reader.utf8(Int(length)) else { return }
            guard let separator = entry.firstIndex(of: "=") else { continue }

            let key = entry[..<separator].uppercased()
            let value = String(entry[entry.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "TITLE":
                metadata.title = metadata.title ?? value
            case "ARTIST":
                metadata.artist = metadata.artist ?? value
            case "ALBUM":
                metadata.album = metadata.album ?? value
            case "METADATA_BLOCK_PICTURE":
                if metadata.artwork == nil, let block = Data(base64Encoded: value) {
                    metadata.artwork = pictureImageData(block)
                }
            default:
                break
            }
        }
    }

    /// Parses a FLAC PICTURE block body and returns the raw image bytes. Ogg's
    /// `METADATA_BLOCK_PICTURE` stores the very same structure, base64 encoded.
    static func pictureImageData<S: DataProtocol>(_ block: S) -> Data? {
        var reader = ByteReader(block)
        guard reader.uint32BE() != nil,                                  // picture type
              let mimeLength = reader.uint32BE(), reader.skip(Int(mimeLength)),
              let descriptionLength = reader.uint32BE(), reader.skip(Int(descriptionLength)),
              reader.uint32BE() != nil,                                  // width
              reader.uint32BE() != nil,                                  // height
              reader.uint32BE() != nil,                                  // colour depth
              reader.uint32BE() != nil,                                  // indexed colours
              let imageLength = reader.uint32BE(),
              let image = reader.bytes(Int(imageLength)) else { return nil }
        return image
    }
}

// MARK: - Sequential byte reader

/// Minimal big/little-endian cursor over a byte buffer, bounds-checked so a
/// truncated or malformed file simply fails instead of crashing.
private struct ByteReader<Bytes: DataProtocol> {
    private let bytes: Bytes
    private var index: Bytes.Index

    init(_ bytes: Bytes) {
        self.bytes = bytes
        self.index = bytes.startIndex
    }

    private var remaining: Int { bytes.distance(from: index, to: bytes.endIndex) }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, count <= remaining else { return false }
        bytes.formIndex(&index, offsetBy: count)
        return true
    }

    mutating func uint32LE() -> UInt32? {
        guard remaining >= 4 else { return nil }
        let value = UInt32(bytes[index])
            | UInt32(bytes[bytes.index(index, offsetBy: 1)]) << 8
            | UInt32(bytes[bytes.index(index, offsetBy: 2)]) << 16
            | UInt32(bytes[bytes.index(index, offsetBy: 3)]) << 24
        bytes.formIndex(&index, offsetBy: 4)
        return value
    }

    mutating func uint32BE() -> UInt32? {
        guard remaining >= 4 else { return nil }
        let value = UInt32(bytes[index]) << 24
            | UInt32(bytes[bytes.index(index, offsetBy: 1)]) << 16
            | UInt32(bytes[bytes.index(index, offsetBy: 2)]) << 8
            | UInt32(bytes[bytes.index(index, offsetBy: 3)])
        bytes.formIndex(&index, offsetBy: 4)
        return value
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, count <= remaining else { return nil }
        let end = bytes.index(index, offsetBy: count)
        let slice = bytes[index..<end]
        index = end
        return Data(slice)
    }

    mutating func utf8(_ count: Int) -> String? {
        bytes(count).flatMap { String(data: $0, encoding: .utf8) }
    }
}
