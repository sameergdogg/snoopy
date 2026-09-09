import Foundation

/// A single request/response exchange, built up incrementally from hook events.
public struct Exchange: Identifiable, Sendable, Hashable {
    public enum State: String, Sendable { case pending, responded, complete, failed }

    public let id: String
    public var taskId: Int?
    public var pid: Int32?
    public var process: String?

    public var method: String
    public var url: URL?
    public var urlString: String
    public var requestHeaders: [String: String]
    public var requestBody: Data?
    public var requestBodySize: Int?
    public var requestBodyTruncated: Bool
    public var requestBodyOmitted: String?

    public var status: Int?
    public var mimeType: String?
    public var responseHeaders: [String: String]
    public var responseBody: Data?
    public var responseBodySize: Int?
    public var responseBodyTruncated: Bool

    public var startedAt: Date
    public var respondedAt: Date?
    public var completedAt: Date?
    public var metrics: Timing?
    public var errorMessage: String?
    public var errorCode: Int?

    public var state: State

    public init(id: String, method: String = "GET", urlString: String = "", startedAt: Date = Date()) {
        self.id = id
        self.method = method
        self.urlString = urlString
        self.url = URL(string: urlString)
        self.requestHeaders = [:]
        self.requestBodyTruncated = false
        self.responseHeaders = [:]
        self.responseBodyTruncated = false
        self.startedAt = startedAt
        self.state = .pending
    }

    public var host: String { url?.host ?? "" }
    public var path: String { url?.path.isEmpty == false ? url!.path : "/" }
    public var scheme: String { url?.scheme ?? "" }

    public var duration: TimeInterval? {
        guard let completedAt else { return nil }
        return completedAt.timeIntervalSince(startedAt)
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (a: Exchange, b: Exchange) -> Bool { a.id == b.id }
}

/// Detailed connection timing captured from URLSessionTaskMetrics (best effort).
public struct Timing: Sendable, Hashable {
    public var fetchStart, dnsStart, dnsEnd, connectStart, connectEnd: Date?
    public var tlsStart, tlsEnd, requestStart, requestEnd, responseStart, responseEnd: Date?
    public var networkProtocol: String?
    public var remoteAddress: String?
    public var reused: Bool?
    public var redirectCount: Int?
    public init() {}
}
