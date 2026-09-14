import XCTest
@testable import SnoopyCore
@testable import SnoopyIPC

/// Headers were a `[String: String]`, which collapsed repeated fields. `Set-Cookie` is the
/// one that matters: a response setting three cookies displayed one, and the HAR export
/// claimed the same.
final class HeadersTests: XCTestCase {

    func testDuplicatesAndOrderSurvive() {
        var h = Headers()
        h.append(name: "Set-Cookie", value: "a=1")
        h.append(name: "Set-Cookie", value: "b=2")
        h.append(name: "Content-Type", value: "application/json")

        XCTAssertEqual(h.count, 3)
        XCTAssertEqual(h.all("set-cookie"), ["a=1", "b=2"])
        XCTAssertEqual(h.first("Set-Cookie"), "a=1")
        XCTAssertEqual(h.map(\.name), ["Set-Cookie", "Set-Cookie", "Content-Type"],
                       "wire order is preserved")
    }

    func testLookupIsCaseInsensitive() {
        let h: Headers = ["Content-Type": "text/html"]
        XCTAssertEqual(h["content-type"], "text/html")
        XCTAssertEqual(h["CONTENT-TYPE"], "text/html")
        XCTAssertNil(h["content_type"], "only letters fold — '_' and '-' are distinct")
        XCTAssertTrue(h.contains("Content-Type"))
    }

    func testASCIIFoldingDoesNotConflateSeparators() {
        // `byte | 0x20` alone would equate '_' (0x5f) with '?' (0x3f), so folding is
        // restricted to letters.
        XCTAssertFalse("a_b".caseInsensitiveASCIICompare("a?b"))
        XCTAssertTrue("X-Req-Id".caseInsensitiveASCIICompare("x-req-id"))
        XCTAssertFalse("abc".caseInsensitiveASCIICompare("abcd"))
    }

    /// The wire format is an ordered array now; the old object form must still decode so a
    /// stale injected dylib in someone's app bundle keeps working.
    func testDecoderAcceptsBothWireFormats() {
        let modern = HookEventDecoder.decode([
            "type": "response", "id": "1",
            "headers": [["Set-Cookie", "a=1"], ["Set-Cookie", "b=2"]],
        ])
        guard case .response(let r)? = modern else { return XCTFail() }
        XCTAssertEqual(r.headers.all("Set-Cookie"), ["a=1", "b=2"])

        let legacy = HookEventDecoder.decode([
            "type": "response", "id": "1",
            "headers": ["Content-Type": "application/json"],
        ])
        guard case .response(let l)? = legacy else { return XCTFail() }
        XCTAssertEqual(l.headers["Content-Type"], "application/json")
    }

    func testHARExportsEveryHeaderAndBreaksOutCookies() throws {
        var e = Exchange(id: "1", method: "GET", urlString: "https://x.com/a")
        e.responseHeaders = Headers([
            .init(name: "Set-Cookie", value: "sid=abc; Path=/"),
            .init(name: "Set-Cookie", value: "tok=xyz; HttpOnly"),
        ])
        e.setStatus(200)

        let obj = try JSONSerialization.jsonObject(with: HARExport.data(from: [e])) as! [String: Any]
        let entry = ((obj["log"] as! [String: Any])["entries"] as! [[String: Any]])[0]
        let response = entry["response"] as! [String: Any]

        let names = (response["headers"] as! [[String: String]]).map { $0["name"]! }
        XCTAssertEqual(names, ["Set-Cookie", "Set-Cookie"], "both cookies reach the export")

        let cookies = response["cookies"] as! [[String: Any]]
        XCTAssertEqual(cookies.map { $0["name"] as! String }, ["sid", "tok"])
        XCTAssertEqual(cookies.first?["value"] as? String, "abc")
    }
}

final class SessionTests: XCTestCase {

    private func sampleExchange() -> Exchange {
        var e = Exchange(id: "ex-1", method: "POST", urlString: "https://api.example.com/v1/items?page=2")
        e.requestHeaders = Headers([.init(name: "Content-Type", value: "application/json"),
                                    .init(name: "X-Trace", value: "abc")])
        e.responseHeaders = Headers([.init(name: "Set-Cookie", value: "a=1"),
                                     .init(name: "Set-Cookie", value: "b=2")])
        e.requestBody = Data(#"{"q":"café"}"#.utf8)
        e.responseBody = Data(repeating: 0xFE, count: 2_048)   // deliberately not UTF-8
        e.responseBodySize = 2_048
        e.responseBodyTruncated = true
        e.mimeType = "application/json"
        e.completedAt = e.startedAt.addingTimeInterval(0.25)
        e.state = .complete
        var t = Timing()
        t.networkProtocol = "h2"
        t.remoteAddress = "93.184.216.34"
        t.dnsStart = e.startedAt
        t.dnsEnd = e.startedAt.addingTimeInterval(0.01)
        e.metrics = t
        e.setStatus(201)
        return e
    }

    func testRoundTripPreservesEverythingTheUIShows() throws {
        let original = sampleExchange()
        let restored = try Session.decode(try Session.encode([original]))

        XCTAssertEqual(restored.count, 1)
        let r = restored[0]
        XCTAssertEqual(r.id, original.id)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.urlString, original.urlString)
        XCTAssertEqual(r.status, 201)
        XCTAssertEqual(r.state, .complete)
        XCTAssertEqual(r.mimeType, "application/json")
        XCTAssertEqual(r.requestBody, original.requestBody)
        XCTAssertEqual(r.responseBody, original.responseBody, "binary bodies survive byte for byte")
        XCTAssertTrue(r.responseBodyTruncated)
        XCTAssertEqual(r.responseHeaders.all("Set-Cookie"), ["a=1", "b=2"])
        XCTAssertEqual(r.metrics?.networkProtocol, "h2")
        XCTAssertEqual(r.metrics?.remoteAddress, "93.184.216.34")
        XCTAssertEqual(r.startedAt.timeIntervalSince1970,
                       original.startedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(r.duration ?? 0, 0.25, accuracy: 0.001)
    }

    /// Derived fields are not stored, so they must be rebuilt rather than restored.
    func testDerivedFieldsAreRebuiltOnLoad() throws {
        let r = try Session.decode(try Session.encode([sampleExchange()]))[0]
        XCTAssertEqual(r.host, "api.example.com")
        XCTAssertEqual(r.path, "/v1/items")
        XCTAssertEqual(r.url?.scheme, "https")
        XCTAssertTrue(r.searchKey.contains("api.example.com"))
        XCTAssertTrue(r.searchKey.contains("201"))
        XCTAssertFalse(r.startedAtText.isEmpty)
    }

    func testReapedStateSurvives() throws {
        var e = sampleExchange()
        e.releaseBodies()
        let r = try Session.decode(try Session.encode([e]))[0]
        XCTAssertTrue(r.bodiesReaped)
        XCTAssertNil(r.responseBody)
        XCTAssertEqual(r.responseBodySize, 2_048, "the size is still reportable after a reap")
    }

    func testFilesAreCompressed() throws {
        // Highly repetitive bodies, so the win should be unmistakable.
        let rows = (0..<50).map { i -> Exchange in
            var e = Exchange(id: "r\(i)", method: "GET", urlString: "https://x.com/a")
            e.responseBody = Data(String(repeating: "abc", count: 2_000).utf8)
            return e
        }
        let encoded = try Session.encode(rows)
        let raw = rows.reduce(0) { $0 + ($1.responseBody?.count ?? 0) }
        XCTAssertLessThan(encoded.count, raw / 4)
        XCTAssertEqual(try Session.decode(encoded).count, 50)
    }

    func testRejectsAFileThatIsNotASession() {
        XCTAssertThrowsError(try Session.decode(Data("{\"hello\":1}".utf8)))
        XCTAssertThrowsError(try Session.decode(Data("not a file at all".utf8)))
    }

    func testDeflateRoundTrips() throws {
        let payload = Data((0..<5_000).map { UInt8($0 % 251) })
        XCTAssertEqual(try Gzip.inflateRaw(try Gzip.deflateRaw(payload)), payload)
    }
}
