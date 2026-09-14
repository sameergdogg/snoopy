import Foundation

/// Everything expensive about rendering a body, computed once, off the main thread.
///
/// This lived in the detail view as a private struct, which meant none of it could be tested
/// and the display limits were tangled up with SwiftUI. The important behaviour — when the
/// tree view is used, when it falls back to text, and how much is retained for display — is
/// policy worth pinning down in tests.
public struct BodyPreview: Sendable {
    public enum Content: Sendable {
        case json(root: JSONNode, nodeCount: Int)
        case text(TextDocument)
        case image
        case empty
    }

    public enum Mode: Int, Sendable, CaseIterable {
        case pretty = 0, raw = 1, hex = 2
        public var title: String {
            switch self {
            case .pretty: return "Pretty"
            case .raw: return "Raw"
            case .hex: return "Hex"
            }
        }
    }

    public var kind: BodyFormatter.Kind
    public var decoded: Data
    public var content: Content
    /// Explains a fallback or a limit, shown above the content.
    public var note: String?

    /// Backstop against a pathological document. The viewer pages large containers rather
    /// than refusing to render them, so this no longer doubles as a display limit — it is
    /// only here so a hostile or accidental 500 MB array cannot exhaust memory building
    /// one struct per value. The old limit was 60,000, which ordinary API responses exceeded.
    public static let maxTreeNodes = 400_000
    /// Bytes of hex rendered. Lazy chunk rendering makes this affordable; it used to be 4 KB
    /// with no way to see any more of the payload.
    public static let maxHexBytes = 1024 * 1024

    public static func make(data: Data, headers: Headers, mimeType: String?, mode: Mode) -> BodyPreview {
        let decoded = BodyFormatter.decoded(data, headers: headers)
        let kind = BodyFormatter.kind(mimeType: mimeType, headers: headers, data: decoded)

        guard !decoded.isEmpty else {
            return BodyPreview(kind: .empty, decoded: decoded, content: .empty, note: nil)
        }

        switch mode {
        case .hex:
            let dump = BodyFormatter.hexDump(decoded, maxBytes: maxHexBytes)
            let note = decoded.count > maxHexBytes
                ? "Showing the first \(byteText(maxHexBytes)) of \(byteText(decoded.count)). Save the body for the rest."
                : nil
            return BodyPreview(kind: kind, decoded: decoded, content: .text(TextDocument(dump)), note: note)

        case .raw:
            return BodyPreview(kind: kind, decoded: decoded,
                               content: .text(TextDocument(BodyFormatter.text(decoded))), note: nil)

        case .pretty:
            if kind == .image {
                return BodyPreview(kind: kind, decoded: decoded, content: .image, note: nil)
            }
            if kind == .json {
                // One JSONSerialization pass feeds both the tree and the text fallback.
                guard let obj = try? JSONSerialization.jsonObject(with: decoded, options: [.fragmentsAllowed]) else {
                    return BodyPreview(kind: kind, decoded: decoded,
                                       content: .text(TextDocument(BodyFormatter.text(decoded))),
                                       note: "Not valid JSON — showing raw text.")
                }
                if let parsed = JSONNode.parseObject(obj, nodeBudget: maxTreeNodes) {
                    return BodyPreview(kind: kind, decoded: decoded,
                                       content: .json(root: parsed.root, nodeCount: parsed.nodeCount),
                                       note: nil)
                }
                let pretty = BodyFormatter.prettyJSON(object: obj) ?? BodyFormatter.text(decoded)
                return BodyPreview(kind: kind, decoded: decoded, content: .text(TextDocument(pretty)),
                                   note: "Over \(maxTreeNodes.formatted()) JSON values — showing pretty-printed text.")
            }
            return BodyPreview(kind: kind, decoded: decoded,
                               content: .text(TextDocument(BodyFormatter.text(decoded))), note: nil)
        }
    }

    static func byteText(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

public extension JSONNode {
    /// Builds a tree from an already-deserialised object, so callers that also need the
    /// pretty-printed text do not pay for a second parse of the same bytes.
    static func parseObject(_ obj: Any, nodeBudget: Int = .max) -> Parsed? {
        var budget = nodeBudget
        var nextID = 0
        guard let root = try? buildNode(from: obj, key: nil, index: nil, budget: &budget, nextID: &nextID) else { return nil }
        return Parsed(root: root, nodeCount: nextID)
    }
}
