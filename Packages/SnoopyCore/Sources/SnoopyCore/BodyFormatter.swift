import Foundation

/// Decodes and pretty-prints response/request bodies for display.
public enum BodyFormatter {
    public enum Kind: Sendable { case json, text, image, binary, empty }

    public static func kind(mimeType: String?, headers: [String: String], data: Data?) -> Kind {
        guard let data, !data.isEmpty else { return .empty }
        let ct = (mimeType ?? headers.firstValue(forCaseInsensitive: "Content-Type") ?? "").lowercased()
        if ct.contains("json") { return .json }
        if ct.hasPrefix("image/") { return .image }
        if ct.hasPrefix("text/") || ct.contains("xml") || ct.contains("javascript") || ct.contains("urlencoded") { return .text }
        // sniff JSON when no/unknown content type
        if looksLikeJSON(data) { return .json }
        if isProbablyText(data) { return .text }
        return .binary
    }

    /// Returns decompressed bytes if Content-Encoding indicates gzip/deflate; else the input.
    public static func decoded(_ data: Data, headers: [String: String]) -> Data {
        let enc = (headers.firstValue(forCaseInsensitive: "Content-Encoding") ?? "").lowercased()
        if enc.contains("gzip") || enc.contains("deflate") {
            return (try? Gzip.decompress(data)) ?? data
        }
        return data
    }

    public static func prettyJSON(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: opts) else { return nil }
        return String(data: out, encoding: .utf8)
    }

    public static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    public static func hexDump(_ data: Data, maxBytes: Int = 4096) -> String {
        let slice = data.prefix(maxBytes)
        var out = ""
        var offset = 0
        for chunk in slice.chunked(16) {
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            out += String(format: "%08x  %-47s  %@\n", offset, (hex as NSString).utf8String!, ascii)
            offset += chunk.count
        }
        if data.count > maxBytes { out += "… (\(data.count - maxBytes) more bytes)\n" }
        return out
    }

    static func looksLikeJSON(_ data: Data) -> Bool {
        guard let first = data.first(where: { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0a || $0 == 0x0d) }) else { return false }
        return first == 0x7b || first == 0x5b // { or [
    }
    static func isProbablyText(_ data: Data) -> Bool {
        let sample = data.prefix(512)
        var control = 0
        for b in sample where b < 0x09 || (b > 0x0d && b < 0x20) { control += 1 }
        return control == 0
    }
}

public extension Dictionary where Key == String, Value == String {
    func firstValue(forCaseInsensitive key: String) -> String? {
        let lk = key.lowercased()
        return first { $0.key.lowercased() == lk }?.value
    }
}

extension Collection {
    func chunked(_ size: Int) -> [SubSequence] {
        var result: [SubSequence] = []
        var i = startIndex
        while i != endIndex {
            let j = index(i, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(self[i..<j]); i = j
        }
        return result
    }
}
