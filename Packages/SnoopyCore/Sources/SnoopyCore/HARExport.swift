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
    static func headerList(_ h: [String: String]) -> [[String: String]] {
        h.map { ["name": $0.key, "value": $0.value] }
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
            "cookies": [],
        ]
        if let body = e.requestBody {
            request["postData"] = [
                "mimeType": e.requestHeaders.firstValue(forCaseInsensitive: "Content-Type") ?? "application/octet-stream",
                "text": BodyFormatter.text(body),
            ]
        }
        let responseContent: [String: Any] = [
            "size": e.responseBodySize ?? (e.responseBody?.count ?? 0),
            "mimeType": e.mimeType ?? e.responseHeaders.firstValue(forCaseInsensitive: "Content-Type") ?? "",
            "text": e.responseBody.map { BodyFormatter.text($0) } ?? "",
        ]
        let response: [String: Any] = [
            "status": e.status ?? 0,
            "statusText": "",
            "httpVersion": e.metrics?.networkProtocol ?? "HTTP/1.1",
            "headers": headerList(e.responseHeaders),
            "cookies": [],
            "content": responseContent,
            "redirectURL": e.responseHeaders.firstValue(forCaseInsensitive: "Location") ?? "",
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
