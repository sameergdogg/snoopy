import Foundation

/// An HTTP header list: ordered, case-insensitive on lookup, and duplicate-preserving.
///
/// This was a `[String: String]`, which silently collapsed repeated headers — `Set-Cookie`
/// most importantly, but also `Via`, `Link`, `Warning` and `Proxy-Authenticate`. A response
/// setting three cookies showed one, and the HAR export claimed the same. Wire order is kept
/// too: header order is occasionally meaningful, and even when it isn't, seeing what the
/// server actually sent in the order it sent it is the point of an inspector.
public struct Headers: Sendable, Hashable {
    public struct Field: Sendable, Hashable, Codable {
        public let name: String
        public let value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
        // Short keys: a saved session can hold tens of thousands of header fields.
        enum CodingKeys: String, CodingKey { case name = "n", value = "v" }
    }

    public private(set) var fields: [Field]

    public init() { fields = [] }
    public init(_ fields: [Field]) { self.fields = fields }
    public init(_ pairs: [(String, String)]) {
        fields = pairs.map { Field(name: $0.0, value: $0.1) }
    }
    /// Lossy: dictionary input has already lost duplicates and order. Sorted so at least the
    /// display is stable. Kept for the legacy wire format and for tests.
    public init(dictionary: [String: String]) {
        fields = dictionary.sorted { $0.key < $1.key }.map { Field(name: $0.key, value: $0.value) }
    }

    public var isEmpty: Bool { fields.isEmpty }
    public var count: Int { fields.count }

    public mutating func append(name: String, value: String) {
        fields.append(Field(name: name, value: value))
    }

    /// First value for `name`, case-insensitively. Header names are ASCII, so a
    /// byte-wise compare is both correct and far cheaper than `lowercased()` per field.
    public func first(_ name: String) -> String? {
        for f in fields where f.name.caseInsensitiveASCIICompare(name) { return f.value }
        return nil
    }

    /// Every value for `name` — the reason this type exists.
    public func all(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveASCIICompare(name) }.map(\.value)
    }

    public func contains(_ name: String) -> Bool { first(name) != nil }

    /// Convenience for the common "give me this header" read. Returns the *first* match;
    /// use `all(_:)` when duplicates matter.
    public subscript(name: String) -> String? { first(name) }

    /// Lowercased "name: value" lines, for the body/header search index.
    public func searchText() -> String {
        var out = ""
        for f in fields {
            out += f.name; out += ": "; out += f.value; out += "\n"
        }
        return out.lowercased()
    }
}

/// Encoded as a bare array of fields rather than an object, so duplicates and order
/// survive the round-trip the same way they do on the wire.
extension Headers: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.init(try c.decode([Field].self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(fields)
    }
}

extension Headers: Collection {
    public typealias Index = Int
    public var startIndex: Int { fields.startIndex }
    public var endIndex: Int { fields.endIndex }
    public func index(after i: Int) -> Int { fields.index(after: i) }
    public subscript(position: Int) -> Field { fields[position] }
}

extension Headers: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(elements)
    }
}

extension String {
    /// ASCII-only case-insensitive equality. Header names are ASCII by RFC, and this avoids
    /// the Unicode-folding machinery (and two String allocations) `lowercased()` would cost
    /// on a path that runs per field per lookup.
    func caseInsensitiveASCIICompare(_ other: String) -> Bool {
        let a = utf8, b = other.utf8
        guard a.count == b.count else { return false }
        var i = a.startIndex, j = b.startIndex
        while i != a.endIndex {
            let x = a[i] | 0x20, y = b[j] | 0x20
            // Only fold letters; `|0x20` would wrongly equate e.g. '_' (0x5f) and '?' (0x3f).
            let xa = (a[i] >= 65 && a[i] <= 90) || (a[i] >= 97 && a[i] <= 122)
            let ya = (b[j] >= 65 && b[j] <= 90) || (b[j] >= 97 && b[j] <= 122)
            if xa && ya { if x != y { return false } }
            else if a[i] != b[j] { return false }
            i = a.index(after: i); j = b.index(after: j)
        }
        return true
    }
}
