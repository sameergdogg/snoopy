import Foundation

/// A single request/response exchange, built up incrementally from hook events.
///
/// Fields the list and the filter touch on every render (`host`, `path`, `searchKey`,
/// `startedAtText`) are stored and computed once at mutation time, not derived per read —
/// with thousands of rows redrawing at capture rate, re-parsing the URL or allocating a
/// lowercased copy per row per frame is the difference between smooth and beachballing.
public struct Exchange: Identifiable, Sendable, Hashable {
    public enum State: String, Sendable, Codable { case pending, responded, complete, failed }

    public let id: String
    public var taskId: Int?
    public var pid: Int32?
    public var process: String?

    public private(set) var method: String
    public private(set) var url: URL?
    public private(set) var urlString: String
    public var requestHeaders: Headers
    public var requestBody: Data?
    public var requestBodySize: Int?
    public var requestBodyTruncated: Bool
    public var requestBodyOmitted: String?

    public private(set) var status: Int?
    public var mimeType: String?
    public var responseHeaders: Headers
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

    /// Bumped by the store on every mutation, and part of `==`.
    ///
    /// Equality used to compare `id` alone. That is the right answer for the store's own
    /// bookkeeping, but `visible` is an `[Exchange]` handed to a SwiftUI `Table`, and
    /// SwiftUI skips an update when the new collection compares equal to the old one. So an
    /// exchange whose response arrived on a later tick than its request — any request slow
    /// enough to be interesting, or any response large enough to take more than one read —
    /// kept rendering with the status, size and duration it had at the instant the row was
    /// created: a permanent "…". The bytes were captured and the detail pane showed them;
    /// only the row was frozen.
    ///
    /// A counter keeps `==` O(1) — comparing fields would mean comparing body `Data` on
    /// every diff — and cannot go stale the way an explicit field list would, because the
    /// store bumps it in the one place any mutation goes through.
    public private(set) var revision: Int = 0

    public mutating func bumpRevision() { revision &+= 1 }

    /// Derived, cached at mutation time. See the type doc.
    public private(set) var host: String
    public private(set) var path: String
    public private(set) var searchKey: String
    public private(set) var startedAtText: String

    /// Lowercased headers and body text, built only when deep search is switched on.
    /// Off by default: indexing every body roughly doubles what a capture retains, and
    /// most filtering is by host or path.
    public private(set) var deepSearchKey: String?

    public init(id: String, method: String = "GET", urlString: String = "", startedAt: Date = Date()) {
        self.id = id
        self.method = method
        self.urlString = urlString
        self.url = URL(string: urlString)
        self.requestHeaders = Headers()
        self.requestBodyTruncated = false
        self.responseHeaders = Headers()
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
        // The full URL carries the query string, which callers reasonably expect to match.
        if urlString.count > host.count + path.count { k += " "; k += urlString }
        searchKey = k.lowercased()
    }

    /// Builds (or clears) the deep-search index over headers and textual bodies.
    /// Bodies are capped: indexing a 10 MB payload to make it findable costs more than
    /// the feature is worth, and the head of a document is where identifying fields live.
    public static let deepSearchBodyCap = 64 * 1024

    public mutating func rebuildDeepSearchKey(enabled: Bool) {
        guard enabled else { deepSearchKey = nil; return }
        var k = requestHeaders.searchText()
        k += responseHeaders.searchText()
        if let b = requestBody { k += Exchange.indexable(b) }
        if let b = responseBody { k += Exchange.indexable(b) }
        deepSearchKey = k
    }

    private static func indexable(_ data: Data) -> String {
        guard BodyFormatter.isProbablyText(data) || BodyFormatter.looksLikeJSON(data) else { return "" }
        let slice = data.prefix(deepSearchBodyCap)
        return BodyFormatter.text(slice).lowercased() + "\n"
    }

    /// True when this exchange matches `q`, which is already lowercased by the store.
    public func matches(_ q: String, deep: Bool) -> Bool {
        if searchKey.contains(q) { return true }
        if deep, let deepSearchKey { return deepSearchKey.contains(q) }
        return false
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
        // The index is derived from bytes we no longer hold; keeping it would be a second,
        // invisible copy of exactly what the budget just asked us to give back.
        deepSearchKey = nil
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
        (requestBody?.count ?? 0) + (responseBody?.count ?? 0) + (deepSearchKey?.utf8.count ?? 0)
    }

    // Hashing by id alone stays valid: `==` is stricter than the hash, which is the
    // direction the contract requires. The store's id index depends on this.
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (a: Exchange, b: Exchange) -> Bool {
        a.id == b.id && a.revision == b.revision
    }

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
public struct Timing: Sendable, Hashable, Codable {
    public var fetchStart, dnsStart, dnsEnd, connectStart, connectEnd: Date?
    public var tlsStart, tlsEnd, requestStart, requestEnd, responseStart, responseEnd: Date?
    public var networkProtocol: String?
    public var remoteAddress: String?
    public var reused: Bool?
    public var redirectCount: Int?
    public init() {}
}
