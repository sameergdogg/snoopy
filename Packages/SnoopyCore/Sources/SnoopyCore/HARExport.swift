import Foundation

/// Exports exchanges to HAR 1.2 (http://www.softwareishard.com/blog/har-12-spec/).
public enum HARExport {
    public static func data(from exchanges: [Exchange], creator: String = "Snoopy") throws -> Data {
        let entries = exchanges.map { entry(for: $0) }
        let log: [String: Any] = [
            "version": "1.2",
            "creator": ["name": creator, "version": "0.1.0"],
            "entries": entries,
        ]
        return try JSONSerialization.data(withJSONObject: ["log": log], options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
    /// Wire order and duplicates are preserved — HAR's `headers` is an array precisely so
    /// that repeated `Set-Cookie` fields survive, and exporting from a dictionary silently
    /// dropped all but one of them.
    static func headerList(_ h: Headers) -> [[String: String]] {
        h.fields.map { ["name": $0.name, "value": $0.value] }
    }

    /// HAR wants cookies broken out as well as left in the header list.
    static func cookieList(_ h: Headers, header: String) -> [[String: Any]] {
        h.all(header).compactMap { raw -> [String: Any]? in
            let parts = raw.split(separator: ";")
            guard let pair = parts.first, let eq = pair.firstIndex(of: "=") else { return nil }
            let name = pair[pair.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return ["name": name, "value": value]
        }
    }
    static func entry(for e: Exchange) -> [String: Any] {
        var request: [String: Any] = [
            "method": e.method,
            "url": e.urlString,
            "httpVersion": e.metrics?.networkProtocol ?? "HTTP/1.1",
            "headers": headerList(e.requestHeaders),
            "queryString": queryString(e.url),
            "headersSize": -1,
            "bodySize": e.requestBodySize ?? -1,
            "cookies": cookieList(e.requestHeaders, header: "Cookie"),
        ]
        if let body = e.requestBody {
            request["postData"] = [
                "mimeType": e.requestHeaders.first("Content-Type") ?? "application/octet-stream",
                "text": BodyFormatter.text(body),
            ]
        }
        let responseContent: [String: Any] = [
            "size": e.responseBodySize ?? (e.responseBody?.count ?? 0),
            "mimeType": e.mimeType ?? e.responseHeaders.first("Content-Type") ?? "",
            "text": e.responseBody.map { BodyFormatter.text($0) } ?? "",
        ]
        let response: [String: Any] = [
            "status": e.status ?? 0,
            "statusText": "",
            "httpVersion": e.metrics?.networkProtocol ?? "HTTP/1.1",
            "headers": headerList(e.responseHeaders),
            "cookies": cookieList(e.responseHeaders, header: "Set-Cookie"),
            "content": responseContent,
            "redirectURL": e.responseHeaders.first("Location") ?? "",
            "headersSize": -1,
            "bodySize": e.responseBodySize ?? -1,
        ]
        return [
            "startedDateTime": iso(e.startedAt),
            "time": (e.duration ?? 0) * 1000,
            "request": request,
            "response": response,
            "cache": [:],
            "timings": timings(e),
            "serverIPAddress": e.metrics?.remoteAddress ?? "",
        ]
    }
    static func queryString(_ url: URL?) -> [[String: String]] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [] }
        return items.map { ["name": $0.name, "value": $0.value ?? ""] }
    }
    static func ms(_ a: Date?, _ b: Date?) -> Double {
        guard let a, let b else { return -1 }
        return b.timeIntervalSince(a) * 1000
    }
    static func timings(_ e: Exchange) -> [String: Any] {
        guard let m = e.metrics else {
            return ["send": 0, "wait": (e.duration ?? 0) * 1000, "receive": 0]
        }
        return [
            "blocked": -1,
            "dns": ms(m.dnsStart, m.dnsEnd),
            "connect": ms(m.connectStart, m.connectEnd),
            "ssl": ms(m.tlsStart, m.tlsEnd),
            "send": max(0, ms(m.requestStart, m.requestEnd)),
            "wait": max(0, ms(m.requestEnd, m.responseStart)),
            "receive": max(0, ms(m.responseStart, m.responseEnd)),
        ]
    }
}
