import Foundation

/// A parsed, displayable JSON tree. Built from raw bytes via `JSONNode.parse`.
///
/// Node identity is a pre-order integer rather than a `"$.user.items[2].name"` path string.
/// The path form was allocating one String per node — on a large document that is the single
/// biggest cost of the parse, and it made the viewer's expansion/match sets `Set<String>`,
/// so every expand toggle and every search hit hashed a path. Ids are stable for the lifetime
/// of one parse, which is all the viewer needs; `path(toID:)` reconstructs a display path on
/// demand for the one case that wants it (copy path), at O(nodes) for a single lookup.
public struct JSONNode: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case object, array, string, number, bool, null }

    public let id: Int             // pre-order index, stable within one parse
    public let key: String?        // object key, or nil for the root / array elements
    public let index: Int?         // array index, or nil
    public let kind: Kind
    public let scalarText: String  // display text for scalars ("\"abc\"", "42", "true", "null")
    public let rawScalar: String   // unquoted scalar for searching ("abc", "42", ...)
    public let children: [JSONNode]?

    public var isContainer: Bool { kind == .object || kind == .array }
    public var childCount: Int { children?.count ?? 0 }

    /// Computed rather than stored: an array of 50,000 elements used to mean 50,000
    /// "[12345]" strings held for the lifetime of the tree.
    public var indexLabel: String? { index.map { "[\($0)]" } }

    /// One-line summary shown when collapsed, e.g. "{ 3 }" or "[ 5 ]".
    public var collapsedSummary: String {
        switch kind {
        case .object: return "{ \(childCount) }"
        case .array:  return "[ \(childCount) ]"
        default:      return scalarText
        }
    }

    /// The label shown at the start of the row (key or array index).
    public var label: String? { key ?? indexLabel }

    /// Total nodes in this subtree, including itself. Computed once at parse time by the
    /// caller via `parse`'s returned count; recomputing it per render would be O(n) a frame.
    public static func count(of node: JSONNode) -> Int {
        1 + (node.children?.reduce(0) { $0 + count(of: $1) } ?? 0)
    }

    // MARK: Parsing

    private struct BudgetExceeded: Error {}

    public struct Parsed: Sendable {
        public let root: JSONNode
        public let nodeCount: Int
    }

    /// Builds the tree, or returns nil if the document is unparseable or exceeds `nodeBudget`.
    ///
    /// The budget is a backstop against a pathological document, not a display limit: the
    /// viewer pages large containers instead of refusing to show them, so this can be set
    /// far higher than the old 60k and still bound worst-case memory.
    public static func parseDetail(_ data: Data, nodeBudget: Int = .max) -> Parsed? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        var budget = nodeBudget
        var nextID = 0
        guard let root = try? buildNode(from: obj, key: nil, index: nil, budget: &budget, nextID: &nextID) else { return nil }
        return Parsed(root: root, nodeCount: nextID)
    }

    public static func parse(_ data: Data, nodeBudget: Int = .max) -> JSONNode? {
        parseDetail(data, nodeBudget: nodeBudget)?.root
    }

    static func buildNode(from value: Any, key: String?, index: Int?,
                          budget: inout Int, nextID: inout Int) throws -> JSONNode {
        budget -= 1
        if budget < 0 { throw BudgetExceeded() }
        let myID = nextID
        nextID += 1
        switch value {
        case let dict as [String: Any]:
            var kids: [JSONNode] = []
            kids.reserveCapacity(dict.count)
            for k in dict.keys.sorted() {
                kids.append(try buildNode(from: dict[k]!, key: k, index: nil, budget: &budget, nextID: &nextID))
            }
            return JSONNode(id: myID, key: key, index: index, kind: .object,
                            scalarText: "", rawScalar: "", children: kids)
        case let arr as [Any]:
            var kids: [JSONNode] = []
            kids.reserveCapacity(arr.count)
            for (i, v) in arr.enumerated() {
                kids.append(try buildNode(from: v, key: nil, index: i, budget: &budget, nextID: &nextID))
            }
            return JSONNode(id: myID, key: key, index: index, kind: .array,
                            scalarText: "", rawScalar: "", children: kids)
        case let num as NSNumber:
            // Distinguish Bool from numeric (NSNumber bridges both).
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                let b = num.boolValue
                return leaf(myID, key, index, .bool, b ? "true" : "false", b ? "true" : "false")
            }
            let s = numberString(num)
            return leaf(myID, key, index, .number, s, s)
        case let str as String:
            return leaf(myID, key, index, .string, "\"\(str)\"", str)
        case is NSNull:
            return leaf(myID, key, index, .null, "null", "null")
        default:
            let s = "\(value)"
            return leaf(myID, key, index, .string, "\"\(s)\"", s)
        }
    }

    private static func leaf(_ id: Int, _ key: String?, _ index: Int?, _ kind: Kind,
                             _ text: String, _ raw: String) -> JSONNode {
        JSONNode(id: id, key: key, index: index, kind: kind, scalarText: text, rawScalar: raw, children: nil)
    }

    private static func numberString(_ n: NSNumber) -> String {
        let d = n.doubleValue
        if d == d.rounded() && abs(d) < 1e15 { return String(n.int64Value) }
        return n.stringValue
    }

    // MARK: Paths

    /// Reconstructs a JSONPath-ish string for `id`, e.g. `$.user.items[2].name`.
    /// Walks the tree, so this is for user-initiated actions (copy path), not rendering.
    public func path(toID target: Int) -> String? {
        var out: String?
        func walk(_ n: JSONNode, _ prefix: String) -> Bool {
            let here: String
            if let k = n.key { here = "\(prefix).\(k)" }
            else if let i = n.index { here = "\(prefix)[\(i)]" }
            else { here = prefix }
            if n.id == target { out = here; return true }
            for c in n.children ?? [] where walk(c, here) { return true }
            return false
        }
        _ = walk(self, "$")
        return out
    }

    /// Finds a node by id. Used by the viewer for copy-value and expand-subtree.
    public func node(withID target: Int) -> JSONNode? {
        if id == target { return self }
        for c in children ?? [] { if let hit = c.node(withID: target) { return hit } }
        return nil
    }

    /// Re-serialises this subtree as pretty JSON, for "copy value" on a container.
    public func jsonText(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch kind {
        case .object:
            guard let kids = children, !kids.isEmpty else { return "{}" }
            let body = kids.map { "\(inner)\"\($0.key ?? "")\": \($0.jsonText(indent: indent + 1))" }
            return "{\n" + body.joined(separator: ",\n") + "\n\(pad)}"
        case .array:
            guard let kids = children, !kids.isEmpty else { return "[]" }
            let body = kids.map { "\(inner)\($0.jsonText(indent: indent + 1))" }
            return "[\n" + body.joined(separator: ",\n") + "\n\(pad)]"
        default:
            return scalarText
        }
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
    public func search(_ q: String) -> (matches: Set<Int>, ancestors: Set<Int>) {
        var matches = Set<Int>(), ancestors = Set<Int>()
        guard !q.isEmpty else { return (matches, ancestors) }
        _ = collect(q, into: &matches, ancestors: &ancestors)
        return (matches, ancestors)
    }

    @discardableResult
    private func collect(_ q: String, into matches: inout Set<Int>, ancestors: inout Set<Int>) -> Bool {
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
