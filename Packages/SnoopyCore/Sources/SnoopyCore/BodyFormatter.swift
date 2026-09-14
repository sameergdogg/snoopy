import Foundation

/// Decodes and pretty-prints response/request bodies for display.
public enum BodyFormatter {
    public enum Kind: Sendable, Hashable { case json, text, image, binary, empty }

    public static func kind(mimeType: String?, headers: Headers, data: Data?) -> Kind {
        guard let data, !data.isEmpty else { return .empty }
        let ct = (mimeType ?? headers.first("Content-Type") ?? "").lowercased()
        if ct.contains("json") { return .json }
        if ct.hasPrefix("image/") { return .image }
        if ct.hasPrefix("text/") || ct.contains("xml") || ct.contains("javascript") || ct.contains("urlencoded") { return .text }
        // sniff JSON when no/unknown content type
        if looksLikeJSON(data) { return .json }
        if isProbablyText(data) { return .text }
        return .binary
    }

    /// Returns decompressed bytes if Content-Encoding indicates gzip/deflate; else the input.
    public static func decoded(_ data: Data, headers: Headers) -> Data {
        let enc = (headers.first("Content-Encoding") ?? "").lowercased()
        if enc.contains("gzip") || enc.contains("deflate") {
            return (try? Gzip.decompress(data)) ?? data
        }
        return data
    }

    public static func prettyJSON(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return prettyJSON(object: obj)
    }

    /// Pretty-prints an already-parsed object. Splitting this out of `prettyJSON(_:Data)`
    /// means the tree-parse and the text fallback can share one `JSONSerialization` pass;
    /// previously a body that overflowed the tree budget was parsed from bytes twice.
    public static func prettyJSON(object: Any) -> String? {
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: opts) else { return nil }
        return String(data: out, encoding: .utf8)
    }

    public static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    public static func hexDump(_ data: Data, offset: Int = 0, maxBytes: Int = 64 * 1024) -> String {
        let slice = data.dropFirst(offset).prefix(maxBytes)
        var out = ""
        var addr = offset
        for chunk in slice.chunked(16) {
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            out += String(format: "%08x  %-47s  %@\n", addr, (hex as NSString).utf8String!, ascii)
            addr += chunk.count
        }
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

    /// A filename suggestion for "Save body…", derived from the URL and content type.
    public static func suggestedFilename(url: URL?, kind: Kind, mimeType: String?) -> String {
        let stem = url?.lastPathComponent.isEmpty == false ? url!.lastPathComponent : "body"
        if stem.contains(".") { return stem }
        let ext: String
        switch kind {
        case .json: ext = "json"
        case .text: ext = (mimeType ?? "").contains("xml") ? "xml" : "txt"
        case .image: ext = (mimeType ?? "").split(separator: "/").last.map(String.init) ?? "img"
        case .binary, .empty: ext = "bin"
        }
        return "\(stem).\(ext)"
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
