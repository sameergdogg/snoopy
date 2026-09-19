import Foundation

/// Writes a capture as a small set of files designed to be handed to an agent (or a
/// colleague) for investigation.
///
/// A single dump of a capture is the wrong shape for this. Bodies are the bulk of it, most
/// of them are irrelevant to any given question, and one multi-megabyte file forces whoever
/// reads it to take all of it to find any of it. So the export is layered:
///
/// - `summary.md` is small enough to read whole. It leads with what usually matters —
///   failures, slow calls, big payloads, repeated endpoints — and only then lists every
///   exchange, each with the path of its body.
/// - `exchanges.jsonl` is one JSON object per line, so it can be grepped or streamed
///   without parsing the whole file.
/// - `bodies/` holds one file per body, named so the interesting one can be opened directly.
///
/// The intended reading order is summary → the two or three bodies it points at, which is a
/// few KB rather than the whole capture.
public enum AgentExport {

    public struct Options: Sendable {
        /// Bytes kept per body. Enough for an API response to be understood; a body clipped
        /// here says so, and the full bytes are still in a session file or a HAR.
        public var maxBodyBytes = 64 * 1024
        /// Newest N exchanges, or 0 for all.
        public var maxExchanges = 0
        /// Strip credentials from headers and URLs. On by default; see `Redaction`.
        public var redactSecrets = true
        public var includeRequestBodies = true
        /// Rows listed individually in summary.md. The aggregate sections above it cover the
        /// rest, and a table of 10,000 rows is not a summary.
        public var maxSummaryRows = 300

        public init() {}
    }

    public struct Result: Sendable {
        public let directory: URL
        public let exchangeCount: Int
        public let bodyFileCount: Int
        public let totalBytes: Int
    }

    // MARK: Entry point

    /// Creates `<parent>/snoopy-export-<stamp>/` and fills it. Returns where it went.
    @discardableResult
    public static func write(_ exchanges: [Exchange],
                             into parent: URL,
                             options: Options = Options()) throws -> Result {
        let fm = FileManager.default
        let stamp = folderStamp(Date())
        var dir = parent.appendingPathComponent("snoopy-export-\(stamp)", isDirectory: true)
        // Two exports in the same second should not merge into each other.
        var bump = 2
        while fm.fileExists(atPath: dir.path) {
            dir = parent.appendingPathComponent("snoopy-export-\(stamp)-\(bump)", isDirectory: true)
            bump += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let selected = options.maxExchanges > 0 ? Array(exchanges.suffix(options.maxExchanges)) : exchanges
        let prepared = selected.map { options.redactSecrets ? Redaction.redact($0) : $0 }
        let rows = prepared.enumerated().map { Row(seq: $0.offset + 1, exchange: $0.element) }

        let bodiesDir = dir.appendingPathComponent("bodies", isDirectory: true)
        var bodyFiles = 0
        if rows.contains(where: { $0.hasAnyBody }) {
            try fm.createDirectory(at: bodiesDir, withIntermediateDirectories: true)
        }
        for row in rows {
            bodyFiles += try writeBodies(row, into: bodiesDir, options: options)
        }

        try write(readme(options: options), to: dir.appendingPathComponent("README.md"))
        try write(summary(rows, options: options), to: dir.appendingPathComponent("summary.md"))
        try write(jsonl(rows, options: options), to: dir.appendingPathComponent("exchanges.jsonl"))

        let total = (try? fm.subpathsOfDirectory(atPath: dir.path).reduce(0) { sum, sub in
            let attrs = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(sub).path)
            return sum + ((attrs?[.size] as? Int) ?? 0)
        }) ?? 0

        return Result(directory: dir, exchangeCount: rows.count, bodyFileCount: bodyFiles, totalBytes: total)
    }

    // MARK: Row

    struct Row {
        let seq: Int
        let exchange: Exchange

        var hasAnyBody: Bool {
            (exchange.requestBody?.isEmpty == false) || (exchange.responseBody?.isEmpty == false)
        }
        var statusText: String {
            if let s = exchange.status { return String(s) }
            return exchange.state == .failed ? "ERR" : "—"
        }
        var durationMs: Double? { exchange.duration.map { $0 * 1000 } }
        var responseBytes: Int { exchange.responseBodySize ?? exchange.responseBody?.count ?? 0 }
        var isFailure: Bool { exchange.state == .failed || (exchange.status ?? 0) >= 400 }

        /// `0007-GET-api.example.com-v1-users` — sortable, greppable, and readable enough to
        /// pick out of a directory listing.
        var slug: String {
            let host = exchange.host.isEmpty ? "unknown-host" : exchange.host
            let path = exchange.path.split(separator: "/").joined(separator: "-")
            let raw = "\(String(format: "%04d", seq))-\(exchange.method)-\(host)-\(path)"
            let safe = raw.map { ch -> Character in
                ch.isLetter || ch.isNumber || ch == "-" || ch == "." || ch == "_" ? ch : "-"
            }
            return String(String(safe).prefix(90))
        }

        func bodyPath(_ kind: String, ext: String) -> String { "bodies/\(slug)-\(kind).\(ext)" }
    }

    // MARK: Bodies

    private static func writeBodies(_ row: Row, into bodiesDir: URL, options: Options) throws -> Int {
        var written = 0
        if options.includeRequestBodies, let body = row.exchange.requestBody, !body.isEmpty {
            let ext = fileExtension(for: row.exchange.requestHeaders.first("Content-Type"), data: body)
            let url = bodiesDir.appendingPathComponent("\(row.slug)-request.\(ext)")
            try writeBody(body, to: url, options: options)
            written += 1
        }
        if let body = row.exchange.responseBody, !body.isEmpty {
            let ext = fileExtension(for: row.exchange.mimeType
                                    ?? row.exchange.responseHeaders.first("Content-Type"), data: body)
            let url = bodiesDir.appendingPathComponent("\(row.slug)-response.\(ext)")
            try writeBody(body, to: url, options: options)
            written += 1
        }
        return written
    }

    private static func writeBody(_ raw: Data, to url: URL, options: Options) throws {
        // Decompress first: a gzipped body written verbatim is unreadable to whoever opens it.
        let data = (try? Gzip.decompress(raw)) ?? raw
        let kind = BodyFormatter.kind(mimeType: nil, headers: Headers(), data: data)

        if kind == .json, let pretty = BodyFormatter.prettyJSON(data) {
            let (clipped, truncated) = TextDocument.clip(pretty, maxBytes: options.maxBodyBytes)
            let note = truncated
                ? "\n\n/* truncated for export at \(options.maxBodyBytes) bytes — \(data.count) bytes captured */\n"
                : "\n"
            try write(clipped + note, to: url)
            return
        }
        if kind == .text {
            let (clipped, truncated) = TextDocument.clip(BodyFormatter.text(data), maxBytes: options.maxBodyBytes)
            let note = truncated
                ? "\n\n--- truncated for export at \(options.maxBodyBytes) bytes — \(data.count) bytes captured ---\n"
                : ""
            try write(clipped + note, to: url)
            return
        }
        // Binary: keep the real bytes, capped. An agent cannot read them, but the summary
        // says what they are and the file is there if a human wants it.
        try data.prefix(options.maxBodyBytes).write(to: url)
    }

    static func fileExtension(for contentType: String?, data: Data) -> String {
        let ct = (contentType ?? "").lowercased()
        if ct.contains("json") { return "json" }
        if ct.contains("xml") { return "xml" }
        if ct.contains("html") { return "html" }
        if ct.contains("javascript") { return "js" }
        if ct.contains("urlencoded") { return "txt" }
        if ct.hasPrefix("text/") { return "txt" }
        if ct.hasPrefix("image/") {
            return ct.split(separator: "/").last.map(String.init)?.split(separator: ";").first.map(String.init) ?? "img"
        }
        if BodyFormatter.looksLikeJSON(data) { return "json" }
        if BodyFormatter.isProbablyText(data) { return "txt" }
        return "bin"
    }

    // MARK: summary.md

    static func summary(_ rows: [Row], options: Options) -> String {
        var out = "# Snoopy capture summary\n\n"

        guard let first = rows.first, let last = rows.last else {
            return out + "No exchanges captured.\n"
        }

        let failures = rows.filter(\.isFailure)
        let completed = rows.filter { $0.durationMs != nil }
        let totalBytes = rows.reduce(0) { $0 + $1.responseBytes }

        out += "- **Exchanges:** \(rows.count)\n"
        out += "- **Window:** \(first.exchange.startedAtText) – \(last.exchange.startedAtText)"
        if let span = last.exchange.startedAt.timeIntervalSince(first.exchange.startedAt) as TimeInterval?,
           span > 0 {
            out += String(format: " (%.1fs)", span)
        }
        out += "\n"
        out += "- **Failures (4xx/5xx/error):** \(failures.count)\n"
        out += "- **Response bytes:** \(byteText(totalBytes))\n"
        if !completed.isEmpty {
            let ms = completed.compactMap(\.durationMs).sorted()
            out += String(format: "- **Duration:** median %.0f ms, p95 %.0f ms, max %.0f ms\n",
                          percentile(ms, 0.5), percentile(ms, 0.95), ms.last ?? 0)
        }
        if options.redactSecrets {
            out += "- **Credentials redacted** in headers and URLs. Bodies are not redacted.\n"
        }
        out += "\n"

        // Hosts
        out += section("Hosts", rows: groupCounts(rows.map { $0.exchange.host.isEmpty ? "—" : $0.exchange.host }),
                       header: ["Host", "Calls"])

        // Status codes
        out += section("Status", rows: groupCounts(rows.map(\.statusText)), header: ["Status", "Calls"])

        // Failures first: this is what an investigation usually starts from.
        if !failures.isEmpty {
            out += "## Failures\n\n"
            out += table(["#", "Time", "Method", "Status", "URL", "Error", "Body"],
                         failures.prefix(50).map { r in
                [String(r.seq), r.exchange.startedAtText, r.exchange.method, r.statusText,
                 truncate(r.exchange.urlString, 70),
                 r.exchange.errorMessage.map { truncate($0, 40) } ?? "",
                 bodyLink(r)]
            })
            if failures.count > 50 { out += "_…and \(failures.count - 50) more._\n\n" }
        }

        // Slowest
        let slowest = rows.filter { $0.durationMs != nil }
            .sorted { ($0.durationMs ?? 0) > ($1.durationMs ?? 0) }.prefix(10)
        if !slowest.isEmpty {
            out += "## Slowest\n\n"
            out += table(["#", "Duration", "Status", "URL"], slowest.map { r in
                [String(r.seq), String(format: "%.0f ms", r.durationMs ?? 0), r.statusText,
                 truncate(r.exchange.urlString, 80)]
            })
        }

        // Largest
        let largest = rows.filter { $0.responseBytes > 0 }
            .sorted { $0.responseBytes > $1.responseBytes }.prefix(10)
        if !largest.isEmpty {
            out += "## Largest responses\n\n"
            out += table(["#", "Size", "Type", "URL", "Body"], largest.map { r in
                [String(r.seq), byteText(r.responseBytes), r.exchange.mimeType ?? "—",
                 truncate(r.exchange.urlString, 60), bodyLink(r)]
            })
        }

        // Repeated endpoints — the cheapest way to spot an N+1 or a retry storm.
        let repeated = groupCounts(rows.map { "\($0.exchange.method) \($0.exchange.host)\($0.exchange.path)" })
            .filter { $0.1 > 1 }.prefix(15)
        if !repeated.isEmpty {
            out += "## Repeated endpoints\n\n"
            out += table(["Endpoint", "Calls"], repeated.map { [$0.0, String($0.1)] })
        }

        // Everything, in order.
        out += "## All exchanges\n\n"
        let listed = rows.suffix(options.maxSummaryRows)
        if listed.count < rows.count {
            out += "_Showing the newest \(listed.count) of \(rows.count); `exchanges.jsonl` has them all._\n\n"
        }
        out += table(["#", "Time", "Method", "Status", "Host", "Path", "Size", "ms", "Body"],
                     listed.map { r in
            [String(r.seq), r.exchange.startedAtText, r.exchange.method, r.statusText,
             truncate(r.exchange.host, 28), truncate(r.exchange.path, 40),
             r.responseBytes > 0 ? byteText(r.responseBytes) : "—",
             r.durationMs.map { String(format: "%.0f", $0) } ?? "—",
             bodyLink(r)]
        })
        return out
    }

    private static func bodyLink(_ r: Row) -> String {
        guard let body = r.exchange.responseBody, !body.isEmpty else {
            if r.exchange.bodiesReaped, (r.exchange.responseBodySize ?? 0) > 0 { return "_released_" }
            return "—"
        }
        let ext = fileExtension(for: r.exchange.mimeType ?? r.exchange.responseHeaders.first("Content-Type"),
                                data: body)
        return "`\(r.bodyPath("response", ext: ext))`"
    }

    // MARK: exchanges.jsonl

    static func jsonl(_ rows: [Row], options: Options) -> String {
        var out = ""
        for r in rows {
            let e = r.exchange
            var obj: [String: Any] = [
                "seq": r.seq,
                "id": e.id,
                "time": e.startedAtText,
                "startedAt": e.startedAt.timeIntervalSince1970,
                "method": e.method,
                "url": e.urlString,
                "host": e.host,
                "path": e.path,
                "state": e.state.rawValue,
                "requestHeaders": e.requestHeaders.fields.map { [$0.name, $0.value] },
                "responseHeaders": e.responseHeaders.fields.map { [$0.name, $0.value] },
            ]
            obj["status"] = e.status
            obj["mimeType"] = e.mimeType
            obj["durationMs"] = r.durationMs
            obj["requestBytes"] = e.requestBodySize ?? e.requestBody?.count
            obj["responseBytes"] = r.responseBytes
            obj["error"] = e.errorMessage
            obj["errorCode"] = e.errorCode
            obj["protocol"] = e.metrics?.networkProtocol
            obj["remoteAddress"] = e.metrics?.remoteAddress
            obj["reusedConnection"] = e.metrics?.reused
            obj["requestBodyTruncatedAtCapture"] = e.requestBodyTruncated
            obj["responseBodyTruncatedAtCapture"] = e.responseBodyTruncated
            obj["bodiesReleased"] = e.bodiesReaped
            if options.includeRequestBodies, let b = e.requestBody, !b.isEmpty {
                obj["requestBodyFile"] = r.bodyPath("request",
                    ext: fileExtension(for: e.requestHeaders.first("Content-Type"), data: b))
            }
            if let b = e.responseBody, !b.isEmpty {
                obj["responseBodyFile"] = r.bodyPath("response",
                    ext: fileExtension(for: e.mimeType ?? e.responseHeaders.first("Content-Type"), data: b))
            }
            let clean = obj.compactMapValues { $0 is NSNull ? nil : $0 }
            if let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes]),
               let line = String(data: data, encoding: .utf8) {
                out += line + "\n"
            }
        }
        return out
    }

    // MARK: README.md

    static func readme(options: Options) -> String {
        var s = """
        # Snoopy export

        A captured set of HTTP exchanges from an iOS Simulator app, laid out so it can be read
        without loading all of it.

        ## Read in this order

        1. **`summary.md`** — start here. Counts, hosts, status codes, then failures, slowest
           calls, largest responses and repeated endpoints, then a table of every exchange.
           Each row names the file holding that response body.
        2. **`bodies/…`** — open only the bodies `summary.md` points you at. One file per body,
           named `<seq>-<METHOD>-<host>-<path>-<request|response>.<ext>`, so they sort in
           chronological order. JSON is pretty-printed.
        3. **`exchanges.jsonl`** — one JSON object per line, every exchange, full metadata and
           headers, no bodies. Made for `grep` and streaming rather than reading end to end:

               grep '"status":500' exchanges.jsonl
               jq -s 'map(select(.durationMs > 1000)) | sort_by(-.durationMs)' exchanges.jsonl

        ## Notes


        """
        if options.redactSecrets {
            s += """
            - **Credentials in headers and URLs are redacted** — `Authorization`, `Cookie`,
              `Set-Cookie`, API-key headers, and query parameters such as `token` or `sig` are
              replaced with their length. **Response and request bodies are *not* redacted**;
              if a body carries a token, it is still in `bodies/`.

            """
        } else {
            s += """
            - **Redaction was turned off for this export.** Authorization headers, cookies and
              tokens are present verbatim. Treat these files as credentials.

            """
        }
        s += """
        - Bodies are truncated at \(options.maxBodyBytes) bytes each; a truncated file says so at
          the end. Sizes in `summary.md` and `exchanges.jsonl` are the real captured sizes.
        - `Content-Encoding: gzip` bodies are decompressed here.
        - "released" in the body column means the capture dropped those bytes to stay inside its
          memory budget; the row and its size survived, the body did not.
        - Times are the app's local clock, `HH:MM:SS.mmm`.
        """
        return s
    }

    // MARK: Formatting helpers

    static func table(_ header: [String], _ rows: [[String]]) -> String {
        var out = "| " + header.joined(separator: " | ") + " |\n"
        out += "|" + header.map { _ in "---" }.joined(separator: "|") + "|\n"
        for r in rows {
            out += "| " + r.map(escapeCell).joined(separator: " | ") + " |\n"
        }
        return out + "\n"
    }

    private static func section(_ title: String, rows: [(String, Int)], header: [String]) -> String {
        guard !rows.isEmpty else { return "" }
        return "## \(title)\n\n" + table(header, rows.prefix(20).map { [$0.0, String($0.1)] })
    }

    /// A pipe in a URL or a header value would otherwise break the table it sits in.
    static func escapeCell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
         .replacingOccurrences(of: "\n", with: " ")
    }

    static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    static func groupCounts(_ values: [String]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let i = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[max(0, min(sorted.count - 1, i))]
    }

    static func byteText(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    static func folderStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}
