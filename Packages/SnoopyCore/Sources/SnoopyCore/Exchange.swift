import Foundation

/// A single request/response exchange, built up incrementally from hook events.
///
/// Fields the list and the filter touch on every render (`host`, `path`, `searchKey`,
/// `startedAtText`) are stored and computed once at mutation time, not derived per read —
/// with thousands of rows redrawing at capture rate, re-parsing the URL or allocating a
/// lowercased copy per row per frame is the difference between smooth and beachballing.
public struct Exchange: Identifiable, Sendable, Hashable {
    public enum State: String, Sendable { case pending, responded, complete, failed }

    public let id: String
    public var taskId: Int?
    public var pid: Int32?
    public var process: String?

    public private(set) var method: String
    public private(set) var url: URL?
    public private(set) var urlString: String
    public var requestHeaders: [String: String]
    public var requestBody: Data?
    public var requestBodySize: Int?
    public var requestBodyTruncated: Bool
    public var requestBodyOmitted: String?

    public private(set) var status: Int?
    public var mimeType: String?
    public var responseHeaders: [String: String]
    public var responseBody: Data?
    public var responseBodySize: Int?
    public var responseBodyTruncated: Bool

    public private(set) var startedAt: Date
    public var respondedAt: Date?
    public var completedAt: Date?
    public var metrics: Timing?
    public var errorMessage: String?
    public var errorCode: Int?

    public var state: State

    /// True once the store released this exchange's bodies to stay inside its memory
    /// budget. The row and its sizes survive; the bytes do not.
    public private(set) var bodiesReaped = false

    /// Derived, cached at mutation time. See the type doc.
    public private(set) var host: String
    public private(set) var path: String
    public private(set) var searchKey: String
    public private(set) var startedAtText: String

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
        self.host = self.url?.host ?? ""
        let p = self.url?.path ?? ""
        self.path = p.isEmpty ? "/" : p
        self.searchKey = ""
        self.startedAtText = Exchange.clockText(startedAt)
        rebuildSearchKey()
    }

    // MARK: Mutation

    public mutating func setRequestLine(method: String, urlString: String) {
        self.method = method
        self.urlString = urlString
        let u = URL(string: urlString)
        self.url = u
        self.host = u?.host ?? ""
        let p = u?.path ?? ""
        self.path = p.isEmpty ? "/" : p
        rebuildSearchKey()
    }

    public mutating func setStatus(_ status: Int?) {
        guard self.status != status else { return }
        self.status = status
        rebuildSearchKey()
    }

    public mutating func setStartedAt(_ date: Date) {
        startedAt = date
        startedAtText = Exchange.clockText(date)
    }

    private mutating func rebuildSearchKey() {
        var k = method
        k += " "
        k += host
        k += " "
        k += path
        if let status { k += " "; k += String(status) }
        searchKey = k.lowercased()
    }

    /// Drops retained body bytes, returning how many were freed. Sizes are kept so the
    /// UI can still say how big the payload was.
    @discardableResult
    public mutating func releaseBodies() -> Int {
        let freed = retainedBytes
        guard freed > 0 else { bodiesReaped = true; return 0 }
        if requestBodySize == nil { requestBodySize = requestBody?.count }
        if responseBodySize == nil { responseBodySize = responseBody?.count }
        requestBody = nil
        responseBody = nil
        bodiesReaped = true
        return freed
    }

    // MARK: Derived

    public var scheme: String { url?.scheme ?? "" }

    public var duration: TimeInterval? {
        guard let completedAt else { return nil }
        return completedAt.timeIntervalSince(startedAt)
    }

    /// Body bytes this exchange keeps alive, for the store's memory budget.
    public var retainedBytes: Int {
        (requestBody?.count ?? 0) + (responseBody?.count ?? 0)
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (a: Exchange, b: Exchange) -> Bool { a.id == b.id }

    // MARK: Clock formatting

    /// `DateFormatter` costs microseconds per call; this runs once per exchange and is
    /// pure integer math on the wall-clock offset captured at launch.
    private static let tzOffset = TimeInterval(TimeZone.current.secondsFromGMT())

    public static func clockText(_ date: Date) -> String {
        let local = date.timeIntervalSince1970 + tzOffset
        let dayFloor = (local / 86400).rounded(.down) * 86400
        let sod = local - dayFloor                       // seconds into the local day
        let whole = Int(sod)
        let ms = Int((sod - Double(whole)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", whole / 3600, (whole % 3600) / 60, whole % 60, ms)
    }
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
