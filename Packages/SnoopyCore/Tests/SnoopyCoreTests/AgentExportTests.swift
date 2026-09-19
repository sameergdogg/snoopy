import XCTest
@testable import SnoopyCore

final class RedactionTests: XCTestCase {

    func testCredentialHeadersAreRedactedAndTheSchemeSurvives() {
        let h: Headers = ["Authorization": "Bearer abc123def456",
                          "Cookie": "sid=xyz",
                          "Content-Type": "application/json"]
        let r = Redaction.redact(h)
        XCTAssertEqual(r["Authorization"], "Bearer <redacted 12 chars>",
                       "the scheme is diagnostic and is not itself a secret")
        XCTAssertEqual(r["Cookie"], "<redacted 7 chars>")
        XCTAssertEqual(r["Content-Type"], "application/json", "ordinary headers are untouched")
    }

    /// A substring match would redact X-Request-Id for containing "request"; matching is exact.
    func testOrdinaryHeadersAreNotCaughtByAccident() {
        let h: Headers = ["X-Request-Id": "abc", "X-Signature-Version": "4", "Authorization-Info": "hi"]
        let r = Redaction.redact(h)
        XCTAssertEqual(r["X-Request-Id"], "abc")
        XCTAssertEqual(r["X-Signature-Version"], "4")
        XCTAssertEqual(r["Authorization-Info"], "hi")
    }

    func testDuplicateHeadersAreEachRedacted() {
        var h = Headers()
        h.append(name: "Set-Cookie", value: "a=1")
        h.append(name: "Set-Cookie", value: "bb=22")
        let r = Redaction.redact(h)
        XCTAssertEqual(r.all("Set-Cookie"), ["<redacted 3 chars>", "<redacted 5 chars>"])
    }

    func testQueryCredentialsAreRedactedAndTheRestIsPreserved() {
        let out = Redaction.redact(urlString: "https://api.x.com/v1/me?user=42&access_token=SECRETVALUE&page=2")
        XCTAssertTrue(out.contains("user=42"))
        XCTAssertTrue(out.contains("page=2"))
        XCTAssertFalse(out.contains("SECRETVALUE"))
        XCTAssertEqual(out, "https://api.x.com/v1/me?user=42&access_token=redacted-11-chars&page=2",
                       "the placeholder must be URL-safe, or it percent-encodes into noise")
    }

    func testUnparseableURLIsLeftAlone() {
        XCTAssertEqual(Redaction.redact(urlString: "not a url at all"), "not a url at all")
        XCTAssertEqual(Redaction.redact(urlString: "https://x.com/no-query"), "https://x.com/no-query")
    }
}

final class AgentExportTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snoopy-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func exchange(_ id: String, method: String = "GET",
                          url: String = "https://api.example.com/v1/users",
                          status: Int? = 200, body: Data? = nil,
                          ms: Double = 100, error: String? = nil) -> Exchange {
        var e = Exchange(id: id, method: method, urlString: url)
        e.requestHeaders = ["Authorization": "Bearer supersecrettoken", "Accept": "application/json"]
        e.responseHeaders = ["Content-Type": "application/json"]
        e.mimeType = "application/json"
        e.responseBody = body
        e.responseBodySize = body?.count
        e.completedAt = e.startedAt.addingTimeInterval(ms / 1000)
        if let error { e.errorMessage = error; e.state = .failed } else { e.state = .complete }
        e.setStatus(status)
        return e
    }

    private func contents(_ dir: URL, _ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    /// The shape of the whole feature: a summary small enough to read, metadata that can be
    /// grepped, and bodies as separate files rather than one giant blob.
    func testProducesLayeredFiles() throws {
        let rows = [exchange("a", body: Data(#"{"name":"ada"}"#.utf8)),
                    exchange("b", url: "https://cdn.example.com/img.png", status: 404, ms: 20)]
        let result = try AgentExport.write(rows, into: tmp)

        let fm = FileManager.default
        for name in ["README.md", "summary.md", "exchanges.jsonl"] {
            XCTAssertTrue(fm.fileExists(atPath: result.directory.appendingPathComponent(name).path),
                          "\(name) must exist")
        }
        XCTAssertEqual(result.exchangeCount, 2)
        XCTAssertEqual(result.bodyFileCount, 1, "only the exchange with a body gets a body file")

        // One JSON object per line, so it streams and greps.
        let lines = try contents(result.directory, "exchanges.jsonl")
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }

    func testSummaryLeadsWithWhatMattersAndPointsAtBodies() throws {
        var rows = (0..<5).map { exchange("ok\($0)", ms: 50) }
        rows.append(exchange("slow", url: "https://api.example.com/v1/slow", ms: 5_000))
        rows.append(exchange("boom", url: "https://api.example.com/v1/boom",
                             status: 500, body: Data(#"{"error":"kaboom"}"#.utf8), error: "server error"))
        let result = try AgentExport.write(rows, into: tmp)
        let summary = try contents(result.directory, "summary.md")

        XCTAssertTrue(summary.contains("## Failures"))
        XCTAssertTrue(summary.contains("kaboom") || summary.contains("server error"))
        XCTAssertTrue(summary.contains("## Slowest"))
        XCTAssertTrue(summary.contains("/v1/slow"))
        XCTAssertTrue(summary.contains("## Repeated endpoints"), "5 identical calls should be flagged")
        // The body pointer is the mechanism that keeps the summary small.
        XCTAssertTrue(summary.contains("bodies/"), "rows must name the file holding their body")
    }

    func testCredentialsAreRedactedByDefault() throws {
        let e = exchange("a", url: "https://api.example.com/v1/me?access_token=TOPSECRETTOKEN")
        let result = try AgentExport.write([e], into: tmp)
        let jsonl = try contents(result.directory, "exchanges.jsonl")
        let summary = try contents(result.directory, "summary.md")

        XCTAssertFalse(jsonl.contains("supersecrettoken"), "Authorization must not be exported")
        XCTAssertFalse(jsonl.contains("TOPSECRETTOKEN"), "query tokens must not be exported")
        XCTAssertFalse(summary.contains("TOPSECRETTOKEN"))
        XCTAssertTrue(jsonl.contains("redacted"))
        XCTAssertTrue(try contents(result.directory, "README.md")
            .contains("bodies are *not* redacted") || contents(result.directory, "README.md")
            .contains("not* redacted"), "the README must not imply bodies are safe")
    }

    func testRedactionCanBeTurnedOffAndTheReadmeSaysSo() throws {
        var options = AgentExport.Options()
        options.redactSecrets = false
        let result = try AgentExport.write([exchange("a")], into: tmp, options: options)
        XCTAssertTrue(try contents(result.directory, "exchanges.jsonl").contains("supersecrettoken"))
        XCTAssertTrue(try contents(result.directory, "README.md").contains("turned off"))
    }

    func testBodiesAreSeparateFilesPrettyPrintedAndCapped() throws {
        let big = Data(("[" + (0..<4_000).map { "{\"i\":\($0)}" }.joined(separator: ",") + "]").utf8)
        var options = AgentExport.Options()
        options.maxBodyBytes = 2_000
        let result = try AgentExport.write([exchange("a", body: big)], into: tmp, options: options)

        let bodies = try FileManager.default.contentsOfDirectory(
            atPath: result.directory.appendingPathComponent("bodies").path)
        XCTAssertEqual(bodies.count, 1)
        let text = try String(contentsOf: result.directory
            .appendingPathComponent("bodies").appendingPathComponent(bodies[0]), encoding: .utf8)
        XCTAssertTrue(text.contains("truncated for export"), "a clipped body must say so")
        XCTAssertLessThan(text.utf8.count, 4_000, "the cap is what keeps the export small")
        XCTAssertTrue(text.hasPrefix("[\n"), "JSON bodies are pretty-printed for reading")

        // The real captured size is still reported, so the cap cannot mislead.
        XCTAssertTrue(try contents(result.directory, "exchanges.jsonl").contains("\"responseBytes\":\(big.count)"))
    }

    func testBodyFilenamesSortChronologicallyAndAreSafe() throws {
        let rows = (0..<12).map {
            exchange("e\($0)", url: "https://api.example.com/v1/a b/../weird?x=1",
                     body: Data("{}".utf8))
        }
        let result = try AgentExport.write(rows, into: tmp)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: result.directory.appendingPathComponent("bodies").path).sorted()
        XCTAssertEqual(names.count, 12)
        XCTAssertTrue(names[0].hasPrefix("0001-"), "zero padding keeps capture order in a listing")
        XCTAssertTrue(names.last!.hasPrefix("0012-"))
        for n in names {
            XCTAssertFalse(n.contains("/"), "a path separator would escape the bodies directory")
            XCTAssertFalse(n.contains(" "))
        }
    }

    func testGzippedBodyIsDecompressedForTheReader() throws {
        let plain = Data(#"{"hello":"world"}"#.utf8)
        var wrapped = Data([0x78, 0x9c])
        wrapped.append(try Gzip.deflateRaw(plain))
        wrapped.append(Data([0, 0, 0, 0]))

        var e = exchange("a", body: wrapped)
        e.responseHeaders = ["Content-Type": "application/json", "Content-Encoding": "gzip"]
        let result = try AgentExport.write([e], into: tmp)
        let bodies = try FileManager.default.contentsOfDirectory(
            atPath: result.directory.appendingPathComponent("bodies").path)
        let text = try String(contentsOf: result.directory
            .appendingPathComponent("bodies").appendingPathComponent(bodies[0]), encoding: .utf8)
        XCTAssertTrue(text.contains("\"hello\""), "a gzipped body would be unreadable verbatim")
    }

    func testTwoExportsInTheSameSecondDoNotCollide() throws {
        let a = try AgentExport.write([exchange("a")], into: tmp)
        let b = try AgentExport.write([exchange("b")], into: tmp)
        XCTAssertNotEqual(a.directory, b.directory)
    }

    func testEmptyCaptureStillProducesAReadableExport() throws {
        let result = try AgentExport.write([], into: tmp)
        XCTAssertEqual(result.exchangeCount, 0)
        XCTAssertTrue(try contents(result.directory, "summary.md").contains("No exchanges"))
    }

    /// A pipe in a value would otherwise silently add a column to the row it sits in.
    func testPipesInValuesDoNotBreakTheMarkdownTable() {
        let rendered = AgentExport.table(["A", "B"], [["x|y", "plain"]])
        let row = rendered.split(separator: "\n").first { $0.contains("plain") }!
        XCTAssertTrue(row.contains("x\\|y"), "the pipe must be escaped")
        let cells = row.replacingOccurrences(of: "\\|", with: "§").split(separator: "|")
        XCTAssertEqual(cells.count, 2, "escaping keeps the row at two columns")
    }

    func testMaxExchangesKeepsTheNewest() throws {
        let rows = (0..<10).map { exchange("e\($0)", url: "https://api.example.com/v1/\($0)") }
        var options = AgentExport.Options()
        options.maxExchanges = 3
        let result = try AgentExport.write(rows, into: tmp, options: options)
        XCTAssertEqual(result.exchangeCount, 3)
        let jsonl = try contents(result.directory, "exchanges.jsonl")
        XCTAssertTrue(jsonl.contains("/v1/9"))
        XCTAssertFalse(jsonl.contains("/v1/0"))
    }
}

/// Not an assertion — writes a sample export to $SNOOPY_SAMPLE_EXPORT so the real output
/// can be eyeballed. Skipped unless that variable is set.
final class AgentExportSampleTests: XCTestCase {
    func testWriteSample() throws {
        guard let dest = ProcessInfo.processInfo.environment["SNOOPY_SAMPLE_EXPORT"] else {
            throw XCTSkip("set SNOOPY_SAMPLE_EXPORT to write a sample")
        }
        var rows: [Exchange] = []
        for i in 0..<6 {
            var e = Exchange(id: "e\(i)", method: i % 3 == 0 ? "POST" : "GET",
                             urlString: "https://api.example.com/v1/search?q=a|b|c&access_token=SECRETTOKEN123")
            e.requestHeaders = ["Authorization": "Bearer supersecrettokenvalue", "Accept": "application/json"]
            e.responseHeaders = ["Content-Type": "application/json"]
            e.mimeType = "application/json"
            e.responseBody = Data(#"{"items":[{"id":1,"name":"ada"},{"id":2,"name":"grace"}]}"#.utf8)
            e.responseBodySize = e.responseBody?.count
            e.completedAt = e.startedAt.addingTimeInterval(Double(i) * 0.4)
            e.state = .complete
            e.setStatus(i == 4 ? 500 : 200)
            if i == 4 { e.errorMessage = "internal error"; e.state = .failed }
            rows.append(e)
        }
        let r = try AgentExport.write(rows, into: URL(fileURLWithPath: dest))
        print("SAMPLE_EXPORT_AT \(r.directory.path)")
    }
}
