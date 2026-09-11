import XCTest
@testable import SnoopyIPC
@testable import SnoopyCore

/// Covers the behaviour the performance pass depends on. These are correctness tests for
/// the optimised paths — if they regress, the app goes back to beachballing.
final class FrameParserStreamTests: XCTestCase {
    func frame(_ obj: [String: Any]) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: obj)
        var len = UInt32(json.count).bigEndian
        var out = Data(bytes: &len, count: 4); out.append(json); return out
    }

    /// The read-offset rewrite must yield exactly the same frames, in order, when many
    /// frames arrive back to back — this is where the old splice-from-front went quadratic.
    func testManyFramesInOrder() {
        var p = FrameParser()
        var buf = Data()
        for i in 0..<500 { buf.append(frame(["type": "log", "message": "m\(i)"])) }
        let out = p.append(buf)
        XCTAssertEqual(out.count, 500)
        XCTAssertEqual(out.first?["message"] as? String, "m0")
        XCTAssertEqual(out.last?["message"] as? String, "m499")
    }

    /// Frames delivered one byte at a time must still reassemble correctly.
    func testByteAtATimeReassembly() {
        var p = FrameParser()
        var buf = Data()
        for i in 0..<20 { buf.append(frame(["type": "log", "message": "x\(i)"])) }
        var got: [[String: Any]] = []
        for byte in buf { got += p.append(Data([byte])) }
        XCTAssertEqual(got.count, 20)
        XCTAssertEqual(got.last?["message"] as? String, "x19")
    }

    /// Interleaved appends must not lose the partially-buffered tail when compaction runs.
    func testCompactionPreservesPartialTail() {
        var p = FrameParser()
        var big = Data()
        // Enough payload to push past the 1 MiB compaction threshold.
        let filler = String(repeating: "z", count: 200_000)
        for i in 0..<8 { big.append(frame(["type": "log", "message": "\(i)\(filler)"])) }
        let tail = frame(["type": "log", "message": "tail"])
        big.append(tail.prefix(5))                       // deliberately incomplete
        XCTAssertEqual(p.append(big).count, 8)
        let rest = p.append(tail.suffix(from: 5))
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest.first?["message"] as? String, "tail")
    }

    func testBogusLengthResetsStream() {
        var p = FrameParser()
        var bogus = Data([0xFF, 0xFF, 0xFF, 0xFF])       // > maxFrame
        bogus.append(Data(repeating: 0, count: 8))
        XCTAssertTrue(p.append(bogus).isEmpty)
        // Parser recovers for the next connection's frames.
        XCTAssertEqual(p.append(frame(["type": "log", "message": "ok"])).count, 1)
    }
}

final class ExchangeDerivedTests: XCTestCase {
    func testDerivedFieldsTrackTheRequestLine() {
        var e = Exchange(id: "1")
        e.setRequestLine(method: "POST", urlString: "https://api.duolingo.com/2017-06-30/users/1")
        XCTAssertEqual(e.host, "api.duolingo.com")
        XCTAssertEqual(e.path, "/2017-06-30/users/1")
        XCTAssertTrue(e.searchKey.contains("duolingo"))
        XCTAssertTrue(e.searchKey.contains("post"), "searchKey must be prelowercased")
        XCTAssertEqual(e.searchKey, e.searchKey.lowercased())
    }

    func testSearchKeyPicksUpStatus() {
        var e = Exchange(id: "1")
        e.setRequestLine(method: "GET", urlString: "https://x.com/a")
        XCTAssertFalse(e.searchKey.contains("404"))
        e.setStatus(404)
        XCTAssertTrue(e.searchKey.contains("404"))
    }

    func testRootPathNormalises() {
        var e = Exchange(id: "1")
        e.setRequestLine(method: "GET", urlString: "https://x.com")
        XCTAssertEqual(e.path, "/")
    }

    func testClockTextFormat() {
        let e = Exchange(id: "1", startedAt: Date(timeIntervalSince1970: 0))
        // HH:mm:ss.SSS — exact digits depend on the local zone, the shape must not.
        XCTAssertEqual(e.startedAtText.count, 12)
        XCTAssertEqual(e.startedAtText[e.startedAtText.index(e.startedAtText.startIndex, offsetBy: 2)], ":")
        XCTAssertEqual(e.startedAtText[e.startedAtText.index(e.startedAtText.startIndex, offsetBy: 8)], ".")
    }

    func testReleaseBodiesFreesBytesButKeepsSizes() {
        var e = Exchange(id: "1")
        e.requestBody = Data(repeating: 1, count: 1000)
        e.responseBody = Data(repeating: 2, count: 3000)
        XCTAssertEqual(e.retainedBytes, 4000)

        let freed = e.releaseBodies()
        XCTAssertEqual(freed, 4000)
        XCTAssertEqual(e.retainedBytes, 0)
        XCTAssertNil(e.responseBody)
        XCTAssertEqual(e.responseBodySize, 3000, "size must survive so the UI can report it")
        XCTAssertTrue(e.bodiesReaped)
    }
}

final class JSONNodeBudgetTests: XCTestCase {
    func testParseSucceedsInsideBudget() {
        let data = Data(#"{"a":[1,2,3]}"#.utf8)
        XCTAssertNotNil(JSONNode.parse(data, nodeBudget: 100))
    }

    /// A document over budget must return nil so the caller falls back to the text view,
    /// rather than building a tree that takes seconds and hundreds of MB.
    func testParseRefusesOverBudget() {
        let arr = (0..<500).map { "\($0)" }.joined(separator: ",")
        let data = Data("[\(arr)]".utf8)
        XCTAssertNil(JSONNode.parse(data, nodeBudget: 50))
        XCTAssertNotNil(JSONNode.parse(data, nodeBudget: 10_000))
    }

    func testUnlimitedBudgetIsTheDefault() {
        let arr = (0..<2000).map { "\($0)" }.joined(separator: ",")
        XCTAssertNotNil(JSONNode.parse(Data("[\(arr)]".utf8)))
    }

    func testSearchIsCaseInsensitiveWithoutLowercasing() {
        let node = JSONNode.parse(Data(#"{"UserName":"Duo","n":{"deep":"VALUE"}}"#.utf8))!
        let hits = node.search("username")
        XCTAssertEqual(hits.matches.count, 1)
        let deep = node.search("value")
        XCTAssertEqual(deep.matches.count, 1)
        XCTAssertTrue(deep.ancestors.contains("$.n"), "ancestors drive auto-expand")
    }

    func testEmptyQueryMatchesNothing() {
        let node = JSONNode.parse(Data(#"{"a":1}"#.utf8))!
        XCTAssertTrue(node.search("").matches.isEmpty)
    }
}
