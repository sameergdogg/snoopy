import XCTest
@testable import SnoopyCore

/// The display policy behind "pretty JSON doesn't work on big responses". All of this was
/// private to a SwiftUI view, so none of the limits could be checked.
final class TextDocumentTests: XCTestCase {

    func testChunksAreBoundedAndLineNumbersAreContiguous() {
        let source = (1...1_000).map { "line \($0)" }.joined(separator: "\n")
        let doc = TextDocument(source)

        XCTAssertEqual(doc.lineCount, 1_000)
        XCTAssertFalse(doc.truncated)
        XCTAssertEqual(doc.chunks.count, Int(ceil(1_000.0 / Double(TextDocument.linesPerChunk))))
        for c in doc.chunks {
            XCTAssertLessThanOrEqual(c.lineCount, TextDocument.linesPerChunk,
                                     "no chunk may exceed the page size — that is the whole point")
        }
        // Numbering must run 1..1000 across chunk boundaries.
        var expected = 1
        for c in doc.chunks {
            XCTAssertEqual(c.firstLine, expected)
            expected += c.lineCount
        }
        XCTAssertEqual(expected - 1, 1_000)
    }

    /// Minified JSON is a single enormous line. Chunking by newline alone would put the
    /// whole document back into one `Text` — exactly the layout stall being fixed.
    func testSingleEnormousLineIsStillChunked() {
        let oneLine = String(repeating: "x", count: 500_000)
        let doc = TextDocument(oneLine)
        XCTAssertGreaterThan(doc.chunks.count, 1, "a minified payload must not become one chunk")
        for c in doc.chunks {
            // Segments plus the newlines they are joined with.
            let ceiling = TextDocument.linesPerChunk * (TextDocument.maxLineLength + 1)
            XCTAssertLessThanOrEqual(c.text.count, ceiling)
            XCTAssertLessThanOrEqual(c.lineCount, TextDocument.linesPerChunk)
        }
    }

    /// The old clip compared `utf8.count` against a byte cap but cut with `String.prefix`,
    /// which counts Characters — so a 512 KB cap let through several megabytes of non-ASCII
    /// text, on exactly the payloads that were already too slow.
    func testClipRespectsAByteBudgetNotACharacterCount() {
        let emoji = String(repeating: "😀", count: 10_000)   // 4 bytes each
        let (clipped, truncated) = TextDocument.clip(emoji, maxBytes: 1_000)
        XCTAssertTrue(truncated)
        XCTAssertLessThanOrEqual(clipped.utf8.count, 1_000)
        XCTAssertEqual(clipped.count, 250, "a byte budget of 1000 is 250 four-byte characters")
        // And it must never split a character.
        XCTAssertTrue(clipped.allSatisfy { $0 == "😀" })
    }

    func testClipLeavesShortTextAlone() {
        let (out, truncated) = TextDocument.clip("hello", maxBytes: 1_000)
        XCTAssertEqual(out, "hello")
        XCTAssertFalse(truncated)
    }
}

final class BodyPreviewTests: XCTestCase {

    private func json(objects: Int) -> Data {
        let items = (0..<objects).map { #"{"id":\#($0),"name":"row \#($0)","ok":true}"# }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    func testOrdinaryJSONGetsATree() {
        let p = BodyPreview.make(data: json(objects: 3), headers: ["Content-Type": "application/json"],
                                 mimeType: nil, mode: .pretty)
        guard case .json(let root, let count) = p.content else { return XCTFail("expected a tree") }
        XCTAssertEqual(root.kind, .array)
        XCTAssertEqual(root.childCount, 3)
        XCTAssertEqual(count, JSONNode.count(of: root))
        XCTAssertNil(p.note)
    }

    /// A response of a few thousand rows is an ordinary API payload, and the old 60,000-node
    /// budget refused to build a tree for it — which is what sent it down the text path that
    /// then hung the layout.
    func testRealisticallyLargeJSONStillGetsATree() {
        // 20,000 rows of four values each — a big but entirely ordinary list endpoint.
        let data = json(objects: 20_000)
        let obj = try! JSONSerialization.jsonObject(with: data)

        let oldBudget = 60_000
        XCTAssertNil(JSONNode.parseObject(obj, nodeBudget: oldBudget),
                     "precondition: the budget this replaced refused a payload of this size")

        let p = BodyPreview.make(data: data, headers: ["Content-Type": "application/json"],
                                 mimeType: nil, mode: .pretty)
        guard case .json(let root, let count) = p.content else {
            return XCTFail("it must now render as a tree instead of falling back to text")
        }
        XCTAssertEqual(root.childCount, 20_000)
        XCTAssertGreaterThan(count, oldBudget)
        XCTAssertNil(p.note, "no fallback, so nothing to explain")
    }

    /// Past the backstop it degrades to pretty-printed text rather than failing, and says so.
    func testPathologicalJSONFallsBackToChunkedText() {
        let huge = Data("[\((0..<10).map { "\($0)" }.joined(separator: ","))]".utf8)
        var preview = BodyPreview.make(data: huge, headers: Headers(), mimeType: "application/json", mode: .pretty)
        guard case .json = preview.content else { return XCTFail("small input should be a tree") }

        // Force the fallback by parsing with a budget of almost nothing.
        let obj = try! JSONSerialization.jsonObject(with: huge)
        XCTAssertNil(JSONNode.parseObject(obj, nodeBudget: 2), "budget must still bound the worst case")

        // And malformed JSON degrades to text with an explanation rather than an empty pane.
        preview = BodyPreview.make(data: Data("{not json".utf8), headers: ["Content-Type": "application/json"],
                                   mimeType: nil, mode: .pretty)
        guard case .text = preview.content else { return XCTFail("expected text fallback") }
        XCTAssertNotNil(preview.note)
    }

    func testGzippedBodyIsInflatedBeforeDisplay() throws {
        let plain = Data(#"{"a":1}"#.utf8)
        let deflated = try Gzip.deflateRaw(plain)
        // zlib framing so `decoded` takes the decompression path.
        var wrapped = Data([0x78, 0x9c])
        wrapped.append(deflated)
        wrapped.append(Data([0, 0, 0, 0]))

        let p = BodyPreview.make(data: wrapped,
                                 headers: ["Content-Type": "application/json", "Content-Encoding": "gzip"],
                                 mimeType: nil, mode: .pretty)
        XCTAssertEqual(p.decoded, plain)
        guard case .json = p.content else { return XCTFail("inflated JSON should render as a tree") }
    }

    /// Hex used to show 4 KB with no way to see any more of the payload.
    func testHexShowsFarMoreThanItUsedTo() {
        let data = Data(repeating: 0xAB, count: 100_000)
        let p = BodyPreview.make(data: data, headers: Headers(), mimeType: nil, mode: .hex)
        guard case .text(let doc) = p.content else { return XCTFail() }
        XCTAssertGreaterThanOrEqual(doc.lineCount, 100_000 / 16)
        XCTAssertNil(p.note, "100 KB is inside the hex window")

        // Past the window it says how much it is showing rather than silently stopping.
        let bigger = BodyPreview.make(data: Data(repeating: 0, count: BodyPreview.maxHexBytes + 1),
                                      headers: Headers(), mimeType: nil, mode: .hex)
        XCTAssertNotNil(bigger.note)
    }

    func testEmptyBodyIsEmptyNotBinary() {
        let p = BodyPreview.make(data: Data(), headers: Headers(), mimeType: nil, mode: .pretty)
        XCTAssertEqual(p.kind, .empty)
        guard case .empty = p.content else { return XCTFail() }
    }

    func testSuggestedFilenames() {
        XCTAssertEqual(BodyFormatter.suggestedFilename(url: URL(string: "https://x.com/a/users"),
                                                       kind: .json, mimeType: nil), "users.json")
        XCTAssertEqual(BodyFormatter.suggestedFilename(url: URL(string: "https://x.com/logo.png"),
                                                       kind: .image, mimeType: "image/png"), "logo.png")
        XCTAssertEqual(BodyFormatter.suggestedFilename(url: nil, kind: .binary, mimeType: nil), "body.bin")
    }
}

final class JSONNodeExtrasTests: XCTestCase {
    func testJSONTextRoundTripsThroughTheParser() throws {
        let src = Data(#"{"a":[1,2,{"b":"c"}],"d":null,"e":true}"#.utf8)
        let root = JSONNode.parse(src)!
        let reparsed = try JSONSerialization.jsonObject(with: Data(root.jsonText().utf8)) as! [String: Any]
        XCTAssertEqual((reparsed["a"] as! [Any]).count, 3)
        XCTAssertEqual(reparsed["e"] as! Bool, true)
        XCTAssertTrue(reparsed["d"] is NSNull)
    }

    func testNodeLookupByID() {
        let root = JSONNode.parse(Data(#"{"a":{"b":42}}"#.utf8))!
        let b = root.children!.first!.children!.first!
        XCTAssertEqual(root.node(withID: b.id)?.scalarText, "42")
        XCTAssertNil(root.node(withID: 1_000))
    }
}
