import Foundation

/// A parsed, displayable JSON tree. Built from raw bytes via `JSONNode.parse`.
public struct JSONNode: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case object, array, string, number, bool, null }

    public let id: String          // stable path-based id, e.g. "$.user.items[2].name"
    public let key: String?        // object key, or nil for the root / array elements
    public let indexLabel: String? // "[0]" for array elements, else nil
    public let kind: Kind
    public let scalarText: String  // display text for scalars ("\"abc\"", "42", "true", "null")
    public let rawScalar: String   // unquoted scalar for searching ("abc", "42", ...)
    public let children: [JSONNode]?

    public var isContainer: Bool { kind == .object || kind == .array }

    /// One-line summary shown when collapsed, e.g. "{ 3 } " or "[ 5 ]".
    public var collapsedSummary: String {
        switch kind {
        case .object: return "{ \(children?.count ?? 0) }"
        case .array:  return "[ \(children?.count ?? 0) ]"
        default:      return scalarText
        }
    }

    /// The label shown at the start of the row (key or array index).
    public var label: String? { key ?? indexLabel }

    // MARK: Parsing

    private struct BudgetExceeded: Error {}

    /// Builds the tree, or returns nil if the document is unparseable or exceeds `nodeBudget`.
    /// Every node allocates a path string and a struct, so an unbounded document can cost
    /// hundreds of megabytes and seconds of CPU; callers fall back to a text view instead.
    public static func parse(_ data: Data, nodeBudget: Int = .max) -> JSONNode? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        var budget = nodeBudget
        return try? node(from: obj, key: nil, indexLabel: nil, path: "$", budget: &budget)
    }

    private static func node(from value: Any, key: String?, indexLabel: String?, path: String,
                             budget: inout Int) throws -> JSONNode {
        budget -= 1
        if budget < 0 { throw BudgetExceeded() }
        switch value {
        case let dict as [String: Any]:
            var kids: [JSONNode] = []
            kids.reserveCapacity(dict.count)
            for k in dict.keys.sorted() {
                kids.append(try node(from: dict[k]!, key: k, indexLabel: nil, path: "\(path).\(k)", budget: &budget))
            }
            return JSONNode(id: path, key: key, indexLabel: indexLabel, kind: .object,
                            scalarText: "", rawScalar: "", children: kids)
        case let arr as [Any]:
            var kids: [JSONNode] = []
            kids.reserveCapacity(arr.count)
            for (i, v) in arr.enumerated() {
                kids.append(try node(from: v, key: nil, indexLabel: "[\(i)]", path: "\(path)[\(i)]", budget: &budget))
            }
            return JSONNode(id: path, key: key, indexLabel: indexLabel, kind: .array,
                            scalarText: "", rawScalar: "", children: kids)
        case let num as NSNumber:
            // Distinguish Bool from numeric (NSNumber bridges both).
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                let b = num.boolValue
                return leaf(key, indexLabel, path, .bool, b ? "true" : "false", b ? "true" : "false")
            }
            let s = numberString(num)
            return leaf(key, indexLabel, path, .number, s, s)
        case let str as String:
            return leaf(key, indexLabel, path, .string, "\"\(str)\"", str)
        case is NSNull:
            return leaf(key, indexLabel, path, .null, "null", "null")
        default:
            let s = "\(value)"
            return leaf(key, indexLabel, path, .string, "\"\(s)\"", s)
        }
    }

    private static func leaf(_ key: String?, _ idx: String?, _ path: String, _ kind: Kind, _ text: String, _ raw: String) -> JSONNode {
        JSONNode(id: path, key: key, indexLabel: idx, kind: kind, scalarText: text, rawScalar: raw, children: nil)
    }

    private static func numberString(_ n: NSNumber) -> String {
        let d = n.doubleValue
        if d == d.rounded() && abs(d) < 1e15 { return String(n.int64Value) }
        return n.stringValue
    }

    // MARK: Search

    /// True if this node's key or scalar contains `q` (case-insensitive).
    ///
    /// Uses a case-insensitive range search rather than `lowercased().contains()`: the latter
    /// allocates a fresh String for the query *and* the haystack at every node visited.
    public func selfMatches(_ q: String) -> Bool {
        guard !q.isEmpty else { return false }
        if let key, key.range(of: q, options: .caseInsensitive) != nil { return true }
        if !isContainer, rawScalar.range(of: q, options: .caseInsensitive) != nil { return true }
        return false
    }

    /// Collects ids of nodes that match and the ids of all their ancestors (for auto-expand).
    /// Returns (matchIds, ancestorIds).
    public func search(_ q: String) -> (matches: Set<String>, ancestors: Set<String>) {
        var matches = Set<String>(), ancestors = Set<String>()
        guard !q.isEmpty else { return (matches, ancestors) }
        _ = collect(q, into: &matches, ancestors: &ancestors)
        return (matches, ancestors)
    }

    @discardableResult
    private func collect(_ q: String, into matches: inout Set<String>, ancestors: inout Set<String>) -> Bool {
        var anyChildMatched = false
        for child in children ?? [] {
            if child.collect(q, into: &matches, ancestors: &ancestors) { anyChildMatched = true }
        }
        let me = selfMatches(q)
        if me { matches.insert(id) }
        if anyChildMatched { ancestors.insert(id) }
        return me || anyChildMatched
    }
}
