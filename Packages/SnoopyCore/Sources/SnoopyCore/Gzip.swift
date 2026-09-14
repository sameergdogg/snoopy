import Foundation
import Compression

/// Minimal gzip/zlib inflate using libcompression.
public enum Gzip {
    public static func decompress(_ data: Data) throws -> Data {
        guard data.count > 2 else { return data }
        // Detect gzip (1f 8b) vs zlib (78 xx). libcompression wants raw DEFLATE for ZLIB algo? It expects zlib for .zlib.
        let isGzip = data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
        let raw: Data
        if isGzip {
            // Strip 10-byte gzip header (no extra fields handled) and 8-byte trailer.
            guard data.count > 18 else { return data }
            raw = data.subdata(in: (data.startIndex + 10)..<(data.endIndex - 8))
        } else {
            // zlib: strip 2-byte header and 4-byte adler trailer -> raw deflate
            raw = data.subdata(in: (data.startIndex + 2)..<(data.endIndex - 4))
        }
        return try inflateRaw(raw)
    }

    public static func inflateRaw(_ data: Data) throws -> Data {
        var out = Data()
        let bufSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: bufSize, src_ptr: dst, src_size: 0, state: nil)
        var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status == COMPRESSION_STATUS_OK else { throw GzipError.initFailed }
        defer { compression_stream_destroy(&stream) }

        return try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = data.count
            repeat {
                stream.dst_ptr = dst
                stream.dst_size = bufSize
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    out.append(dst, count: bufSize - stream.dst_size)
                default:
                    throw GzipError.decodeFailed
                }
            } while status == COMPRESSION_STATUS_OK
            return out
        }
    }
    /// Raw DEFLATE (RFC 1951) — the same framing `inflateRaw` reads. Note that
    /// libcompression's `COMPRESSION_ZLIB` is raw DEFLATE despite the name, which is why
    /// `decompress` strips the zlib/gzip wrappers before calling into it.
    public static func deflateRaw(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }
        var out = Data()
        let bufSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: bufSize, src_ptr: dst, src_size: 0, state: nil)
        var status = compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
        guard status == COMPRESSION_STATUS_OK else { throw GzipError.initFailed }
        defer { compression_stream_destroy(&stream) }

        return try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = data.count
            repeat {
                stream.dst_ptr = dst
                stream.dst_size = bufSize
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    out.append(dst, count: bufSize - stream.dst_size)
                default:
                    throw GzipError.encodeFailed
                }
            } while status == COMPRESSION_STATUS_OK
            return out
        }
    }

    enum GzipError: Error { case initFailed, decodeFailed, encodeFailed }
}
