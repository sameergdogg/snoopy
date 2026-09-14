import Foundation
import SnoopyCore

/// Decoded events sent by the injected hook over the Unix socket.
public enum HookEvent: Sendable {
    case hello(pid: Int32, process: String, bundleId: String)
    case log(String)
    case request(RequestEvent)
    case response(ResponseEvent)
    case metrics(id: String, timing: Timing)
    case complete(CompleteEvent)

    public struct RequestEvent: Sendable {
        public var id: String
        public var taskId: Int?
        public var t: Double
        public var method: String
        public var url: String
        public var headers: Headers
        public var body: Data?
        public var bodySize: Int?
        public var bodyTruncated: Bool
        public var bodyOmitted: String?
    }
    public struct ResponseEvent: Sendable {
        public var id: String
        public var t: Double
        public var status: Int?
        public var mimeType: String?
        public var headers: Headers
    }
    public struct CompleteEvent: Sendable {
        public var id: String
        public var t: Double
        public var status: Int?
        public var mimeType: String?
        public var headers: Headers
        public var body: Data?
        public var bodySize: Int?
        public var bodyTruncated: Bool
        public var errorMessage: String?
        public var errorCode: Int?
        public var timing: Timing?
    }
}

public enum HookEventDecoder {
    public static func decode(_ json: [String: Any]) -> HookEvent? {
        guard let type = json["type"] as? String else { return nil }
        switch type {
        case "hello":
            return .hello(pid: int32(json["pid"]) ?? 0,
                          process: json["process"] as? String ?? "",
                          bundleId: json["bundleId"] as? String ?? "")
        case "log":
            return .log(json["message"] as? String ?? "")
        case "request":
            guard let id = json["id"] as? String else { return nil }
            return .request(.init(id: id,
                                  taskId: int(json["taskId"]),
                                  t: dbl(json["t"]) ?? 0,
                                  method: json["method"] as? String ?? "GET",
                                  url: json["url"] as? String ?? "",
                                  headers: headers(json["headers"]),
                                  body: data(json["body"]),
                                  bodySize: int(json["bodySize"]),
                                  bodyTruncated: json["bodyTruncated"] as? Bool ?? false,
                                  bodyOmitted: json["bodyOmitted"] as? String))
        case "response":
            guard let id = json["id"] as? String else { return nil }
            return .response(.init(id: id, t: dbl(json["t"]) ?? 0,
                                   status: int(json["status"]),
                                   mimeType: json["mimeType"] as? String,
                                   headers: headers(json["headers"])))
        case "metrics":
            guard let id = json["id"] as? String else { return nil }
            return .metrics(id: id, timing: timing(json))
        case "complete":
            guard let id = json["id"] as? String else { return nil }
            var err: (String, Int)?
            if let e = json["error"] as? [String: Any] {
                err = (e["message"] as? String ?? "", int(e["code"]) ?? 0)
            }
            return .complete(.init(id: id, t: dbl(json["t"]) ?? 0,
                                   status: int(json["status"]),
                                   mimeType: json["mimeType"] as? String,
                                   headers: headers(json["headers"]),
                                   body: data(json["body"]),
                                   bodySize: int(json["bodySize"]),
                                   bodyTruncated: json["bodyTruncated"] as? Bool ?? false,
                                   errorMessage: err?.0, errorCode: err?.1,
                                   timing: (json["metrics"] as? [String: Any]).map { timing($0) }))
        default:
            return nil
        }
    }

    /// Accepts the current wire format — an ordered array of `[name, value]` pairs — and
    /// the legacy object form, so a Snoopy build still works against an older injected
    /// hook that a developer has lying around in a built app bundle.
    static func headers(_ v: Any?) -> Headers {
        if let pairs = v as? [[Any]] {
            var h = Headers()
            for p in pairs where p.count >= 2 {
                h.append(name: "\(p[0])", value: "\(p[1])")
            }
            return h
        }
        if let d = v as? [String: Any] {
            return Headers(dictionary: d.mapValues { "\($0)" })
        }
        return Headers()
    }
    static func data(_ v: Any?) -> Data? {
        guard let s = v as? String else { return nil }
        return Data(base64Encoded: s)
    }
    static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
    static func int32(_ v: Any?) -> Int32? { (v as? NSNumber)?.int32Value }
    static func dbl(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    static func date(_ v: Any?) -> Date? { dbl(v).map { Date(timeIntervalSince1970: $0) } }

    static func timing(_ j: [String: Any]) -> Timing {
        var t = Timing()
        t.fetchStart = date(j["fetchStart"]); t.dnsStart = date(j["dnsStart"]); t.dnsEnd = date(j["dnsEnd"])
        t.connectStart = date(j["connectStart"]); t.connectEnd = date(j["connectEnd"])
        t.tlsStart = date(j["tlsStart"]); t.tlsEnd = date(j["tlsEnd"])
        t.requestStart = date(j["requestStart"]); t.requestEnd = date(j["requestEnd"])
        t.responseStart = date(j["responseStart"]); t.responseEnd = date(j["responseEnd"])
        t.networkProtocol = j["protocol"] as? String
        t.remoteAddress = j["remoteAddress"] as? String
        t.reused = j["reused"] as? Bool
        t.redirectCount = int(j["redirects"])
        return t
    }
}

public extension HookEvent {
    /// Maps a wire event onto the store's vocabulary. `.detached` has no wire equivalent —
    /// the socket server raises it when a reader loop ends.
    var captureEvent: CaptureEvent {
        switch self {
        case .hello(let pid, let process, let bundleId):
            return .attached(pid: pid, process: process, bundleId: bundleId)
        case .log(let m):
            return .log(m)
        case .request(let r):
            return .request(.init(id: r.id, taskId: r.taskId, t: r.t, method: r.method, url: r.url,
                                  headers: r.headers, body: r.body, bodySize: r.bodySize,
                                  bodyTruncated: r.bodyTruncated, bodyOmitted: r.bodyOmitted))
        case .response(let r):
            return .response(.init(id: r.id, t: r.t, status: r.status, mimeType: r.mimeType, headers: r.headers))
        case .metrics(let id, let timing):
            return .metrics(id: id, timing: timing)
        case .complete(let c):
            return .complete(.init(id: c.id, t: c.t, status: c.status, mimeType: c.mimeType,
                                   headers: c.headers, body: c.body, bodySize: c.bodySize,
                                   bodyTruncated: c.bodyTruncated, errorMessage: c.errorMessage,
                                   errorCode: c.errorCode, timing: c.timing))
        }
    }
}
