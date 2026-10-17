import Foundation

// MARK: - EBML byte reader

/// Minimal EBML cursor over a file handle, bounds-checked so a truncated or
/// malformed file simply fails instead of crashing. Shared by the Matroska
/// cover reader and the metadata reader.
final class MatroskaReader {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    var offset: UInt64 { handle.offsetInFile }

    func skip(_ count: UInt64) {
        handle.seek(toFileOffset: handle.offsetInFile + count)
    }

    func seek(to offset: UInt64) {
        handle.seek(toFileOffset: offset)
    }

    /// Reads an element ID, keeping its marker bits (IDs are compared raw).
    func readID() -> UInt64? {
        guard let first = readByte() else { return nil }
        let length = vintLength(first)
        guard (1...4).contains(length) else { return nil }

        var value = UInt64(first)
        for _ in 1..<length {
            guard let byte = readByte() else { return nil }
            value = value << 8 | UInt64(byte)
        }
        return value
    }

    /// Reads a size VINT and strips the marker bit. Returns `nil` for the
    /// "unknown size" encoding (all value bits set).
    func readSize() -> UInt64? {
        guard let first = readByte() else { return nil }
        let length = vintLength(first)
        guard (1...8).contains(length) else { return nil }

        let mask: UInt8 = length >= 8 ? 0 : UInt8(0xFF >> length)
        var value = UInt64(first & mask)
        for _ in 1..<length {
            guard let byte = readByte() else { return nil }
            value = value << 8 | UInt64(byte)
        }

        let unknown = (UInt64(1) << (7 * length)) - 1
        return value == unknown ? nil : value
    }

    /// Reads an unsigned integer element of 1–8 bytes (EBML uint).
    func readUInt(_ count: UInt64) -> UInt64? {
        guard (1...8).contains(count) else { return nil }
        var value: UInt64 = 0
        for _ in 0..<count {
            guard let byte = readByte() else { return nil }
            value = value << 8 | UInt64(byte)
        }
        return value
    }

    func readData(_ count: UInt64) -> Data? {
        guard count <= UInt64(Int.max) else { return nil }
        let data = handle.readData(ofLength: Int(count))
        return UInt64(data.count) == count ? data : nil
    }

    func readString(_ count: UInt64) -> String? {
        readData(count).map { String(decoding: $0, as: UTF8.self) }
    }

    private func readByte() -> UInt8? {
        let data = handle.readData(ofLength: 1)
        return data.isEmpty ? nil : data[data.startIndex]
    }

    /// Number of leading zero bits + 1; 0 when the byte is zero (invalid).
    private func vintLength(_ first: UInt8) -> Int {
        var mask: UInt8 = 0x80
        for length in 1...8 {
            if first & mask != 0 { return length }
            mask >>= 1
        }
        return 0
    }
}
