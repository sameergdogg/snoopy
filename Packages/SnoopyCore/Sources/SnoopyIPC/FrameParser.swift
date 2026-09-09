import Foundation

/// Accumulates bytes and yields complete length-prefixed (UInt32 BE) JSON frames.
public struct FrameParser {
    private var buffer = Data()
    private let maxFrame: Int
    public init(maxFrame: Int = 64 * 1024 * 1024) { self.maxFrame = maxFrame }

    public mutating func append(_ chunk: Data) -> [[String: Any]] {
        buffer.append(chunk)
        var out: [[String: Any]] = []
        while buffer.count >= 4 {
            let len = buffer.withUnsafeBytes { raw -> UInt32 in
                let b = raw.bindMemory(to: UInt8.self)
                return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
            }
            let frameLen = Int(len)
            if frameLen == 0 || frameLen > maxFrame { buffer.removeAll(keepingCapacity: false); break }
            guard buffer.count - 4 >= frameLen else { break }
            let json = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + frameLen))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 4 + frameLen))
            if let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
                out.append(obj)
            }
        }
        return out
    }
}
