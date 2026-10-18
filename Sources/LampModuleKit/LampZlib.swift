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
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
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
