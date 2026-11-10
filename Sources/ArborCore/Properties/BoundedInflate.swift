import Foundation
import Compression

/// DEFLATE from a file, inflated only up to a stated size, so a small stream can't become a large allocation (FE-152).
enum BoundedInflate {
    private static let chunk = 64 << 10

    /// nil when the data is corrupt, ends early or would exceed `limit`.
    static func raw(_ input: Data, limit: Int) -> Data? {
        guard limit >= 0, !input.isEmpty else { return nil }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        return input.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data? in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count
            var output = Data()
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                guard status != COMPRESSION_STATUS_ERROR, produced <= limit - output.count else { return nil }
                output.append(buffer, count: produced)
                if status == COMPRESSION_STATUS_END { return output }
                guard produced > 0 else { return nil }
            }
        }
    }

    /// The zlib wrapper around DEFLATE, which PDF streams use.
    static func zlib(_ input: Data, limit: Int) -> Data? {
        guard input.count > 2, let first = input.first, first & 0x0F == 8, first >> 4 <= 7 else { return nil }
        let second = input[input.startIndex + 1]
        guard (Int(first) << 8 | Int(second)) % 31 == 0, second & 0x20 == 0 else { return nil }
        return raw(input.dropFirst(2), limit: limit)
    }
}
