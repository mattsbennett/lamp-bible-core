import Compression
import Foundation

/// Unpacks zlib data — the raw DEFLATE that `NSData.compressed(using: .zlib)`
/// writes — straight into a file, a chunk at a time.
///
/// A module can unpack to hundreds of megabytes. Unpacking one in memory,
/// beside the sync archive it arrived in, is more than iOS allows an app, so
/// anything bound for disk should come through here rather than through
/// `NSData.decompressed(using:)`.
public enum LampZlib {
    public enum DecompressionError: Error, Equatable {
        /// The data is damaged, or ends before the stream does.
        case invalidData
    }

    /// Replaces whatever is at `url` with the unpacked bytes.
    public static func decompress(_ data: Data, to url: URL) throws {
        try process(data, operation: COMPRESSION_STREAM_DECODE, to: url)
    }

    /// Packs the file at `source` into `url`, a chunk at a time, in the
    /// format `NSData.compressed(using: .zlib)` writes.
    public static func compress(fileAt source: URL, to url: URL) throws {
        try process(Data(contentsOf: source, options: .alwaysMapped), operation: COMPRESSION_STREAM_ENCODE, to: url)
    }

    /// The first `count` unpacked bytes, or all of them if there are fewer,
    /// without unpacking the rest: enough to read a header from a body that
    /// may unpack to hundreds of megabytes.
    /// As much of the unpacked start as `data`, which may be only the start
    /// of a compressed body, yields, up to `count` bytes. Never throws: a
    /// short or truncated input gives a shorter start.
    public static func decompressedStart(of data: Data, upTo count: Int) -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard count > 0, !data.isEmpty,
              compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { return Data() }
        defer { compression_stream_destroy(stream) }
        var start = Data(count: count)
        let produced = start.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let from = source.bindMemory(to: UInt8.self).baseAddress,
                      let to = output.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                stream.pointee.src_ptr = from
                stream.pointee.src_size = source.count
                stream.pointee.dst_ptr = to
                stream.pointee.dst_size = count
                while stream.pointee.dst_size > 0 {
                    let before = stream.pointee.dst_size
                    let status = compression_stream_process(stream, 0)
                    guard status == COMPRESSION_STATUS_OK, stream.pointee.dst_size < before else { break }
                }
                return count - stream.pointee.dst_size
            }
        }
        return start.prefix(produced)
    }

    public static func decompressedPrefix(of data: Data, count: Int) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK
        else { throw DecompressionError.invalidData }
        defer { compression_stream_destroy(stream) }
        var prefix = Data(count: count)
        let produced = try prefix.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) -> Int in
            try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let start = source.bindMemory(to: UInt8.self).baseAddress,
                      let destination = output.bindMemory(to: UInt8.self).baseAddress
                else { throw DecompressionError.invalidData }
                stream.pointee.src_ptr = start
                stream.pointee.src_size = source.count
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = count
                // All the input is given at once, so it is final from the start.
                let finalize = Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue)
                while stream.pointee.dst_size > 0 {
                    let before = stream.pointee.dst_size
                    let status = compression_stream_process(stream, finalize)
                    if status == COMPRESSION_STATUS_END { break }
                    guard status == COMPRESSION_STATUS_OK, stream.pointee.dst_size < before else {
                        throw DecompressionError.invalidData
                    }
                }
                return count - stream.pointee.dst_size
            }
        }
        return prefix.prefix(produced)
    }

    private static func process(_ data: Data, operation: compression_stream_operation, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, operation, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK
        else { throw DecompressionError.invalidData }
        defer { compression_stream_destroy(stream) }

        let chunkSize = 1 << 20
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }

        try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let start = source.bindMemory(to: UInt8.self).baseAddress else {
                throw DecompressionError.invalidData
            }
            stream.pointee.src_ptr = start
            stream.pointee.src_size = source.count
            let finalize = Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue)

            while true {
                stream.pointee.dst_ptr = chunk
                stream.pointee.dst_size = chunkSize
                let status = compression_stream_process(stream, finalize)
                let produced = chunkSize - stream.pointee.dst_size
                if produced > 0 {
                    try autoreleasepool {
                        try handle.write(contentsOf: UnsafeBufferPointer(start: chunk, count: produced))
                    }
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK where produced > 0 || stream.pointee.src_size > 0:
                    continue
                default:
                    // An error, or input exhausted with the stream unfinished:
                    // a truncated module must not pass as a short one.
                    throw DecompressionError.invalidData
                }
            }
        }
    }
}
