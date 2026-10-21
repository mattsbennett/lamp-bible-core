import Foundation

/// Reads the files in a zip archive — enough for the archives Bibles are
/// downloaded in: stored or deflated entries, no encryption, no ZIP64.
struct LampZipArchive {
    struct Entry: Equatable {
        let path: String
        fileprivate let method: UInt16
        fileprivate let compressedSize: Int
        fileprivate let uncompressedSize: Int
        fileprivate let localHeaderOffset: Int

        var isDirectory: Bool { path.hasSuffix("/") }
    }

    enum ReadError: Error, Equatable {
        case notAZipArchive
        case damaged
        /// ZIP64, encryption, or a compression method other than deflate.
        case unsupported
        case entryTooLarge(String)
    }

    /// An entry that unpacks to more than this is refused rather than unpacked:
    /// a whole Bible with every annotation is a few tens of megabytes.
    static let maximumEntrySize = 256 * 1024 * 1024

    private let bytes: [UInt8]
    let entries: [Entry]

    static func isZip(_ data: Data) -> Bool {
        data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || data.starts(with: [0x50, 0x4B, 0x05, 0x06])
    }

    init(data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        guard let end = Self.endOfCentralDirectory(in: bytes) else { throw ReadError.notAZipArchive }

        let entryCount = Int(Self.uint16(bytes, end + 10))
        var offset = Int(Self.uint32(bytes, end + 16))
        guard entryCount != 0xFFFF, offset != 0xFFFF_FFFF else { throw ReadError.unsupported }

        var entries: [Entry] = []
        for _ in 0..<entryCount {
            guard offset + 46 <= bytes.count, Self.uint32(bytes, offset) == 0x0201_4B50 else {
                throw ReadError.damaged
            }
            let flags = Self.uint16(bytes, offset + 8)
            let method = Self.uint16(bytes, offset + 10)
            let compressedSize = Self.uint32(bytes, offset + 20)
            let uncompressedSize = Self.uint32(bytes, offset + 24)
            let nameLength = Int(Self.uint16(bytes, offset + 28))
            let extraLength = Int(Self.uint16(bytes, offset + 30))
            let commentLength = Int(Self.uint16(bytes, offset + 32))
            let localHeaderOffset = Self.uint32(bytes, offset + 42)
            guard offset + 46 + nameLength <= bytes.count else { throw ReadError.damaged }
            guard compressedSize != 0xFFFF_FFFF, uncompressedSize != 0xFFFF_FFFF,
                  localHeaderOffset != 0xFFFF_FFFF else { throw ReadError.unsupported }

            let nameBytes = bytes[(offset + 46)..<(offset + 46 + nameLength)]
            // Bit 11 marks a UTF-8 name; older tools wrote code page 437,
            // which matches Latin-1 for the ASCII names Bible archives use.
            let path = flags & 0x0800 != 0
                ? String(decoding: nameBytes, as: UTF8.self)
                : String(bytes: nameBytes, encoding: .isoLatin1) ?? String(decoding: nameBytes, as: UTF8.self)
            if flags & 0x0001 == 0 {
                entries.append(Entry(
                    path: path,
                    method: method,
                    compressedSize: Int(compressedSize),
                    uncompressedSize: Int(uncompressedSize),
                    localHeaderOffset: Int(localHeaderOffset)
                ))
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    func contents(of entry: Entry) throws -> Data {
        guard entry.uncompressedSize <= Self.maximumEntrySize else { throw ReadError.entryTooLarge(entry.path) }
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, Self.uint32(bytes, header) == 0x0403_4B50 else {
            throw ReadError.damaged
        }
        let start = header + 30 + Int(Self.uint16(bytes, header + 26)) + Int(Self.uint16(bytes, header + 28))
        guard start + entry.compressedSize <= bytes.count else { throw ReadError.damaged }
        let stored = Data(bytes[start..<(start + entry.compressedSize)])

        switch entry.method {
        case 0:
            return stored
        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            // LampZlib's format is raw DEFLATE, which is what a zip entry
            // holds. Asking for one byte more than the header declares bounds
            // the memory a lying header can take and shows the lie.
            guard let inflated = try? LampZlib.decompressedPrefix(of: stored, count: entry.uncompressedSize + 1),
                  inflated.count == entry.uncompressedSize else { throw ReadError.damaged }
            return inflated
        default:
            throw ReadError.unsupported
        }
    }

    private static func endOfCentralDirectory(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        // The record is 22 bytes plus a comment of at most 65,535.
        let earliest = max(0, bytes.count - 22 - 0xFFFF)
        var offset = bytes.count - 22
        while offset >= earliest {
            if uint32(bytes, offset) == 0x0605_4B50 { return offset }
            offset -= 1
        }
        return nil
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
