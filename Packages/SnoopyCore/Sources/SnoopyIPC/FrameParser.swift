import Foundation

/// Accumulates bytes and yields complete length-prefixed (UInt32 BE) JSON frames.
///
/// Consumed frames are tracked with a read offset rather than spliced out of the front of
/// the buffer: `removeSubrange` from index 0 memmoves the entire remainder on every frame,
/// which is quadratic when a burst of large bodies arrives back-to-back. The buffer is
/// compacted only once the consumed prefix is worth reclaiming.
public struct FrameParser {
    private var buffer = Data()
    private var readOffset = 0
    private let maxFrame: Int

    /// Compact when the dead prefix exceeds this, or half the buffer, whichever comes first.
    private static let compactThreshold = 1 << 20   // 1 MiB

    public init(maxFrame: Int = 64 * 1024 * 1024) { self.maxFrame = maxFrame }

    public mutating func append(_ chunk: Data) -> [[String: Any]] {
        buffer.append(chunk)
        var out: [[String: Any]] = []

        while true {
            let available = buffer.count - readOffset
            guard available >= 4 else { break }

            let base = buffer.startIndex + readOffset
            let len = buffer.withUnsafeBytes { raw -> UInt32 in
                let b = raw.bindMemory(to: UInt8.self)
                return (UInt32(b[readOffset]) << 24) | (UInt32(b[readOffset + 1]) << 16)
                     | (UInt32(b[readOffset + 2]) << 8) | UInt32(b[readOffset + 3])
            }
            let frameLen = Int(len)
            // A bogus length means the stream is desynchronised; there is no way to resync,
            // so drop everything buffered and wait for the next connection's frames.
            if frameLen == 0 || frameLen > maxFrame {
                buffer.removeAll(keepingCapacity: false)
                readOffset = 0
                break
            }
            guard available - 4 >= frameLen else { break }

            let json = buffer.subdata(in: (base + 4)..<(base + 4 + frameLen))
            readOffset += 4 + frameLen
            if let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
                out.append(obj)
            }
        }

        compactIfNeeded()
        return out
    }

    private mutating func compactIfNeeded() {
        guard readOffset > 0 else { return }
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            return
        }
        guard readOffset >= Self.compactThreshold || readOffset >= buffer.count / 2 else { return }
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + readOffset))
        readOffset = 0
    }
}
