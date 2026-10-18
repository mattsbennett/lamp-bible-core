import Foundation
import Testing
@testable import LampModuleKit

struct LampZlibTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-zlib-\(UUID().uuidString)")
    }

    /// Several chunks' worth, so the output crosses chunk boundaries.
    private let original = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) })

    @Test func unpacksWhatNSDataPacked() throws {
        let packed = try (original as NSData).compressed(using: .zlib) as Data
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try LampZlib.decompress(packed, to: url)

        #expect(try Data(contentsOf: url) == original)
    }

    @Test func replacesWhatWasAlreadyThere() throws {
        let packed = try (Data("short".utf8) as NSData).compressed(using: .zlib) as Data
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try original.write(to: url)

        try LampZlib.decompress(packed, to: url)

        #expect(try Data(contentsOf: url) == Data("short".utf8))
    }

    @Test func refusesATruncatedStream() throws {
        let packed = try (original as NSData).compressed(using: .zlib) as Data
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: LampZlib.DecompressionError.invalidData) {
            try LampZlib.decompress(packed.prefix(packed.count / 2), to: url)
        }
    }

    @Test func refusesDataThatIsNotZlib() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: LampZlib.DecompressionError.invalidData) {
            try LampZlib.decompress(Data(repeating: 0xFF, count: 64), to: url)
        }
        #expect(throws: LampZlib.DecompressionError.invalidData) {
            try LampZlib.decompress(Data(), to: url)
        }
    }
}
