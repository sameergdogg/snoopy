import XCTest
@testable import SnoopyIPC
@testable import SnoopyCore

final class FrameParserTests: XCTestCase {
    func frame(_ obj: [String: Any]) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: obj)
        var len = UInt32(json.count).bigEndian
        var out = Data(bytes: &len, count: 4); out.append(json); return out
    }

    func testSplitFrameAcrossChunks() {
        var p = FrameParser()
        let f = frame(["type": "log", "message": "hi"])
        XCTAssertTrue(p.append(f.prefix(3)).isEmpty)
        XCTAssertTrue(p.append(f[3..<6]).isEmpty)
        let out = p.append(f.suffix(from: 6))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?["message"] as? String, "hi")
    }

    func testMultipleFramesOneChunk() {
        var p = FrameParser()
        var buf = frame(["type": "request", "id": "a", "method": "GET", "url": "https://x/"])
        buf.append(frame(["type": "complete", "id": "a", "status": 200]))
        let out = p.append(buf)
        XCTAssertEqual(out.count, 2)
    }

    func testDecodeRequestAndComplete() {
        let req = HookEventDecoder.decode(["type": "request", "id": "1", "method": "POST",
                                           "url": "https://api.duolingo.com/login",
                                           "headers": ["Content-Type": "application/json"],
                                           "body": Data("{}".utf8).base64EncodedString(), "bodySize": 2])
        guard case .request(let r)? = req else { return XCTFail() }
        XCTAssertEqual(r.method, "POST"); XCTAssertEqual(r.bodySize, 2)
        XCTAssertEqual(r.headers["Content-Type"], "application/json")

        let done = HookEventDecoder.decode(["type": "complete", "id": "1", "status": 200,
                                            "metrics": ["protocol": "h2", "remoteAddress": "1.2.3.4"]])
        guard case .complete(let c)? = done else { return XCTFail() }
        XCTAssertEqual(c.status, 200); XCTAssertEqual(c.timing?.networkProtocol, "h2")
    }
}

final class BodyFormatterTests: XCTestCase {
    func testJSONKindAndPretty() {
        let d = Data(#"{"b":1,"a":2}"#.utf8)
        XCTAssertEqual(BodyFormatter.kind(mimeType: "application/json", headers: Headers(), data: d), .json)
        let pretty = BodyFormatter.prettyJSON(d)
        XCTAssertNotNil(pretty)
        XCTAssertTrue(pretty!.contains("\"a\" : 2"))
    }
    func testHARRoundTrips() throws {
        var e = Exchange(id: "1", method: "GET", urlString: "https://x.com/a?q=1")
        e.setStatus(200); e.responseBody = Data("hi".utf8); e.completedAt = e.startedAt.addingTimeInterval(0.1)
        let har = try HARExport.data(from: [e])
        let obj = try JSONSerialization.jsonObject(with: har) as! [String: Any]
        let log = obj["log"] as! [String: Any]
        XCTAssertEqual((log["entries"] as! [[String: Any]]).count, 1)
    }
}

final class JSONNodeTests: XCTestCase {
    let sample = Data("""
    {"user":{"name":"sameer","admin":true,"streak":42},"items":[{"id":1},{"id":2}],"note":null}
    """.utf8)

    func testParseShape() {
        let root = JSONNode.parse(sample)!
        XCTAssertEqual(root.kind, .object)
        XCTAssertEqual(root.children?.count, 3)   // user, items, note (sorted keys)
        let user = root.children!.first { $0.key == "user" }!
        XCTAssertEqual(user.kind, .object)
        let admin = user.children!.first { $0.key == "admin" }!
        XCTAssertEqual(admin.kind, .bool); XCTAssertEqual(admin.scalarText, "true")
        let streak = user.children!.first { $0.key == "streak" }!
        XCTAssertEqual(streak.kind, .number); XCTAssertEqual(streak.scalarText, "42")
        let items = root.children!.first { $0.key == "items" }!
        XCTAssertEqual(items.kind, .array); XCTAssertEqual(items.children?.count, 2)
        XCTAssertEqual(items.children?.first?.indexLabel, "[0]")
        let note = root.children!.first { $0.key == "note" }!
        XCTAssertEqual(note.kind, .null)
    }

    func testSearchMatchesAndAncestors() {
        let root = JSONNode.parse(sample)!
        let user = root.children!.first { $0.key == "user" }!
        let name = user.children!.first { $0.key == "name" }!
        let streak = user.children!.first { $0.key == "streak" }!

        let (matches, ancestors) = root.search("sameer")
        XCTAssertTrue(matches.contains(name.id))
        XCTAssertTrue(ancestors.contains(user.id))   // parent auto-expands
        XCTAssertTrue(ancestors.contains(root.id))
        // key search
        XCTAssertTrue(root.search("streak").matches.contains(streak.id))
        // number search
        XCTAssertTrue(root.search("42").matches.contains(streak.id))
    }

    /// Ids identify a node within one parse; paths are reconstructed only on demand.
    func testPathsAreDerivedNotStored() {
        let root = JSONNode.parse(sample)!
        let items = root.children!.first { $0.key == "items" }!
        let second = items.children![1]
        let id = second.children!.first { $0.key == "id" }!
        XCTAssertEqual(root.path(toID: id.id), "$.items[1].id")
        XCTAssertEqual(root.path(toID: root.id), "$")
        XCTAssertNil(root.path(toID: 9_999))
    }

    func testIdsArePreOrderAndUnique() {
        let root = JSONNode.parse(sample)!
        var seen = Set<Int>()
        func walk(_ n: JSONNode) {
            XCTAssertTrue(seen.insert(n.id).inserted, "node ids must be unique")
            for c in n.children ?? [] { walk(c) }
        }
        walk(root)
        XCTAssertEqual(root.id, 0, "root is first in pre-order")
        XCTAssertEqual(seen.count, JSONNode.count(of: root))
    }
}
