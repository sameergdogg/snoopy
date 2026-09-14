import Foundation
import SwiftUI
import Darwin

/// One column of the timeline strip: how many exchanges started in this slice, by outcome.
public struct TimelineBucket: Identifiable, Equatable, Sendable {
    public let index: Int
    public var start: Date
    public var ok = 0
    public var warn = 0
    public var error = 0
    public var pending = 0

    public var id: Int { index }
    public var total: Int { ok + warn + error + pending }
}

/// What the capture is doing right now, as one value the UI can render without deriving it
/// from three separate booleans.
///
/// The app previously had no notion of "started" at all: it began listening in the
/// controller's initialiser and the only control was a Pause toggle, so there was nothing
/// to press to begin and nothing that reported whether anything was attached.
public enum RecordingState: Sendable, Equatable {
    /// Recording, but no injected process has connected yet.
    case waiting
    /// Recording with at least one process attached.
    case recording
    /// User paused. Rows already captured keep updating to completion; no new ones start.
    case paused

    public var isRecording: Bool { self != .paused }

    public var label: String {
        switch self {
        case .waiting:   return "Waiting for app"
        case .recording: return "Recording"
        case .paused:    return "Paused"
        }
    }
    public var symbol: String {
        switch self {
        case .waiting:   return "dot.radiowaves.left.and.right"
        case .recording: return "record.circle.fill"
        case .paused:    return "pause.circle.fill"
        }
    }
}

/// A process that has the hook injected and is currently connected.
public struct AttachedProcess: Identifiable, Sendable, Hashable {
    public let pid: Int32
    public let name: String
    public let bundleId: String
    public var id: Int32 { pid }
    public init(pid: Int32, name: String, bundleId: String) {
        self.pid = pid; self.name = name; self.bundleId = bundleId
    }
}

/// Lock-protected handoff between the socket's reader threads and the main actor.
final class EventInbox<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func push(_ item: Element) {
        lock.lock(); items.append(item); lock.unlock()
    }
    func drain() -> [Element] {
        lock.lock(); defer { lock.unlock() }
        let out = items
        items.removeAll(keepingCapacity: true)
        return out
    }
}

/// Holds captured exchanges and applies hook events. UI-facing; mutated on the main actor.
///
/// Three invariants keep this cheap under a firehose (a chatty app can produce hundreds of
/// events a second with multi-megabyte bodies):
///
/// 1. Events are queued off-main and applied in one batch per frame, so the main actor sees
///    at most one publish per tick regardless of arrival rate.
/// 2. `index` stores *absolute* positions offset by `evictedCount`, so evicting the oldest
///    rows never rebuilds the id map.
/// 3. Retained body bytes are budgeted. Over budget, the oldest bodies are released while
///    their rows stay, so history survives but memory does not grow without bound.
///
/// It lives in the package rather than the app target so its semantics — which events a
/// paused capture accepts, what eviction does to the id index, how the row window behaves —
/// can be tested. The pause bug this class shipped with was invisible precisely because
/// none of that was reachable from a test.
@MainActor
public final class CaptureStore: ObservableObject {
    // Published surface. `exchanges` is deliberately *not* published: republishing the whole
    // history on every mutation is what made the table re-diff thousands of rows per event.
    @Published public private(set) var visible: [Exchange] = []
    @Published public private(set) var timeline: [TimelineBucket] = []
    @Published public private(set) var timelineSpan: ClosedRange<Date>?
    @Published public private(set) var totalCount = 0
    /// How many rows match the filter and time range, before the display window below.
    @Published public private(set) var matchCount = 0
    @Published public private(set) var retainedBytes = 0
    @Published public private(set) var droppedCount = 0
    /// Rows the live-capture window is currently holding back. Zero when everything matching
    /// is on screen, which is the normal case once you pause or filter.
    @Published public private(set) var withheldCount = 0

    @Published public private(set) var attached: [AttachedProcess] = []
    @Published public var statusLine: String = "Ready — press Record, then launch an app"

    /// User intent. The single source of truth for whether new exchanges are accepted.
    @Published public private(set) var isRecording = true

    public var recordingState: RecordingState {
        if !isRecording { return .paused }
        return attached.isEmpty ? .waiting : .recording
    }

    @Published public var filterText: String = "" {
        didSet { guard oldValue != filterText else { return }; republish() }
    }
    /// Time range brushed on the timeline, or nil for "everything".
    @Published public var selectedRange: ClosedRange<Date>? {
        didSet { guard oldValue != selectedRange else { return }; republish() }
    }
    /// Extend the filter to headers and textual bodies. Off by default — see `Exchange`.
    @Published public var deepSearch = false {
        didSet { guard oldValue != deepSearch else { return }; reindexForDeepSearch() }
    }
    /// Lift the live row window and show every matching row, whatever it costs.
    @Published public var showAllRows = false {
        didSet { guard oldValue != showAllRows else { return }; republish() }
    }

    public private(set) var exchanges: [Exchange] = []   // newest last, full retained history

    // MARK: Limits

    /// Rows kept before the oldest are dropped entirely.
    public var maxExchanges = 10_000
    /// Body bytes kept before the oldest bodies are released (rows survive).
    public var maxRetainedBytes = 256 * 1024 * 1024
    /// Rows are evicted in chunks so the array memmove amortises instead of running per event.
    private let evictChunk = 512
    /// Rows handed to the `Table` **while recording**.
    ///
    /// `Table` turns a row-set change into an `NSTableView` batch update, and a delta of a
    /// few thousand rows wedges AppKit inside `endUpdates` for minutes at 100% CPU. That is
    /// a property of large deltas arriving at capture rate, though — not of large tables.
    /// So the window applies only while rows are actually streaming in; pause (or filter, or
    /// brush a range) and the full matching history becomes scrollable. Previously the cap
    /// was unconditional, which meant a finished capture of 10,000 rows would only ever let
    /// you see the newest 1,000 of them.
    public var maxLiveRows = 2_000

    // MARK: Indexing

    private var index: [String: Int] = [:]   // id -> absolute position
    private var evictedCount = 0             // absolute position of exchanges[0]
    private var reapCursor = 0               // absolute position of the oldest un-reaped body

    // MARK: Batching

    private let inbox = EventInbox<CaptureEvent>()
    private var pump: DispatchSourceTimer?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var needsRefilter = false
    private var forcePublish = false
    private var lastPublish = Date.distantPast
    private var lastTimelineRebuild = Date.distantPast

    private static let flushInterval = 0.033          // ~30 Hz
    private static let timelineInterval = 0.2         // ~5 Hz; the strip does not need frame rate
    private static let timelineBuckets = 240

    // MARK: Ingest

    /// - Parameter pumped: false in tests, where `flush()` is called explicitly so behaviour
    ///   is deterministic instead of depending on a timer firing.
    public init(pumped: Bool = true) {
        if pumped {
            startPump()
            startMemoryPressureWatch()
        }
    }

    /// Called from the socket's background threads. Deliberately does no main-actor work:
    /// hopping to the main actor once per event is what saturated the run loop under load.
    /// The pump below picks events up on the next tick.
    nonisolated public func enqueue(_ event: CaptureEvent) {
        inbox.push(event)
    }

    /// Single coalescing drain at ~30 Hz. Idle ticks cost a dictionary-empty check, so this
    /// can run for the lifetime of the app without showing up in a profile.
    private func startPump() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval, leeway: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.resume()
        pump = timer
    }

    /// Applies everything queued and republishes immediately, bypassing the rate limiter.
    public func flush() {
        forcePublish = true
        tick()
    }

    /// Recomputes the visible rows now, for a change the *user* made.
    ///
    /// Every one of these used to only raise a flag and wait for the pump. That was already
    /// a latency wart for typing and brushing, and for the recording toggle it was a bug:
    /// on an idle app no tick ever had work to do, so pressing Record changed the icon and
    /// nothing else.
    private func republish() {
        needsRefilter = true
        flush()
    }

    private func tick() {
        let batch = inbox.drain()
        guard !batch.isEmpty || needsRefilter else { return }

        var changed = false
        for e in batch where apply(e) { changed = true }

        if changed {
            enforceLimits()
            totalCount = exchanges.count
            needsRefilter = true
        }
        guard needsRefilter else { return }

        let now = Date()
        guard forcePublish || now.timeIntervalSince(lastPublish) >= publishInterval else { return }
        forcePublish = false
        needsRefilter = false
        lastPublish = now
        rebuildVisible()
    }

    /// Publishing the row array makes SwiftUI re-diff the whole table, and it walks every
    /// row rather than just the visible ones — under load that diff, not our own work,
    /// dominates the main thread. So the publish rate is scaled down as the list grows.
    /// Nothing is dropped, it just lands in fewer, larger updates; a list of thousands of
    /// rows scrolling past at 30 Hz is unreadable anyway. User-driven changes (typing a
    /// filter, brushing the timeline, pausing) bypass this via `forcePublish`.
    private var publishInterval: Double {
        switch exchanges.count {
        case ..<2_000:  return 0.033   // ~30 Hz
        case ..<10_000: return 0.1     // ~10 Hz
        default:        return 0.2     // ~5 Hz
        }
    }

    // MARK: Recording control

    public func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        statusLine = attached.isEmpty
            ? "Recording — waiting for an app to attach"
            : "Recording \(attached.map(\.name).joined(separator: ", "))"
        // Without this the row window stays at its paused size and nothing repaints until
        // the next event lands, so on an idle app pressing Record appeared to do nothing.
        republish()
    }

    public func pauseRecording() {
        guard isRecording else { return }
        isRecording = false
        statusLine = "Paused — \(totalCount.formatted()) captured"
        republish()
    }

    public func toggleRecording() {
        isRecording ? pauseRecording() : startRecording()
    }

    public func clear() {
        exchanges.removeAll()
        index.removeAll()
        visible.removeAll()
        timeline.removeAll()
        timelineSpan = nil
        selectedRange = nil
        evictedCount = 0
        reapCursor = 0
        retainedBytes = 0
        totalCount = 0
        matchCount = 0
        droppedCount = 0
        withheldCount = 0
        lastTimelineRebuild = .distantPast
    }

    /// O(1) lookup for the detail pane. A linear scan here ran on every render.
    public func exchange(id: Exchange.ID) -> Exchange? {
        guard let abs = index[id] else { return nil }
        let pos = abs - evictedCount
        guard exchanges.indices.contains(pos) else { return nil }
        return exchanges[pos]
    }

    /// Replaces the whole capture, for loading a saved session.
    public func load(_ loaded: [Exchange]) {
        clear()
        for e in loaded { append(e) }
        totalCount = exchanges.count
        enforceLimits()
        pauseRecording()
        statusLine = "Loaded \(exchanges.count.formatted()) exchanges"
        republish()
    }

    // MARK: Apply

    /// Returns true when the exchange list changed in a way the UI must see.
    private func apply(_ event: CaptureEvent) -> Bool {
        switch event {
        case .attached(let pid, let process, let bundleId):
            if !attached.contains(where: { $0.pid == pid }) {
                attached.append(AttachedProcess(pid: pid, name: process, bundleId: bundleId))
            }
            statusLine = isRecording ? "Recording \(process) (pid \(pid))" : "Paused — \(process) attached"
            return false
        case .detached(let pid):
            attached.removeAll { $0.pid == pid }
            statusLine = attached.isEmpty
                ? "App disconnected — \(totalCount.formatted()) captured"
                : "Recording \(attached.map(\.name).joined(separator: ", "))"
            return false
        case .log:
            return false
        case .request(let r):
            // A paused capture starts nothing new. Exchanges already in flight are still
            // allowed to finish below, so pausing does not strand them as "pending" forever.
            guard isRecording else { return false }
            var e = Exchange(id: r.id)
            e.taskId = r.taskId
            e.setRequestLine(method: r.method, urlString: r.url)
            e.requestHeaders = r.headers
            e.requestBody = r.body
            e.requestBodySize = r.bodySize
            e.requestBodyTruncated = r.bodyTruncated
            e.requestBodyOmitted = r.bodyOmitted
            e.setStartedAt(Date(timeIntervalSince1970: r.t))
            e.state = .pending
            if index[r.id] != nil {
                // Duplicate request id: keep the existing row and refresh it in place.
                return update(r.id) { $0 = e }
            }
            append(e)
            return true
        case .response(let r):
            return update(r.id) { e in
                e.setStatus(r.status)
                e.mimeType = r.mimeType
                if !r.headers.isEmpty { e.responseHeaders = r.headers }
                e.respondedAt = Date(timeIntervalSince1970: r.t)
                if e.state == .pending { e.state = .responded }
            }
        case .metrics(let id, let timing):
            return update(id) { $0.metrics = timing }
        case .complete(let c):
            return update(c.id) { e in
                if let s = c.status { e.setStatus(s) }
                if let m = c.mimeType { e.mimeType = m }
                if !c.headers.isEmpty { e.responseHeaders = c.headers }
                if let b = c.body { e.responseBody = b }
                e.responseBodySize = c.bodySize
                e.responseBodyTruncated = c.bodyTruncated
                e.completedAt = Date(timeIntervalSince1970: c.t)
                if let t = c.timing { e.metrics = t }
                if let msg = c.errorMessage, !msg.isEmpty {
                    e.errorMessage = msg; e.errorCode = c.errorCode; e.state = .failed
                } else {
                    e.state = .complete
                }
                e.rebuildDeepSearchKey(enabled: deepSearch)
            }
        }
    }

    private func append(_ e: Exchange) {
        var e = e
        e.rebuildDeepSearchKey(enabled: deepSearch)
        exchanges.append(e)
        index[e.id] = evictedCount + exchanges.count - 1
        retainedBytes += e.retainedBytes
    }

    /// Mutates an existing exchange. Crucially it does **not** create one.
    ///
    /// This was an upsert, and every late event — response, metrics, completion — went
    /// through it. While paused, `.request` was dropped but the responses that followed
    /// still arrived, so each one *created* a row: method "GET", no URL, no host, and a
    /// start time of whenever the response happened to land. Those phantom rows outlived
    /// the pause, skewed the timeline, and were exported to HAR as if they were real
    /// traffic. A response with no request is not an exchange anyone can use, in either
    /// state, so the only thing that opens a row now is a request.
    @discardableResult
    private func update(_ id: String, _ mutate: (inout Exchange) -> Void) -> Bool {
        guard let abs = index[id] else { return false }
        let pos = abs - evictedCount
        guard exchanges.indices.contains(pos) else { return false }   // already evicted
        let before = exchanges[pos].retainedBytes
        mutate(&exchanges[pos])
        // Every mutation funnels through here, so this is the one place that has to
        // remember to mark the row dirty for SwiftUI. See `Exchange.revision`.
        exchanges[pos].bumpRevision()
        retainedBytes += exchanges[pos].retainedBytes - before
        return true
    }

    // MARK: Deep search index

    private func reindexForDeepSearch() {
        let on = deepSearch
        var delta = 0
        for i in exchanges.indices {
            let before = exchanges[i].retainedBytes
            exchanges[i].rebuildDeepSearchKey(enabled: on)
            delta += exchanges[i].retainedBytes - before
        }
        retainedBytes += delta
        if on { reapBodiesIfNeeded() }
        republish()
    }

    // MARK: Limits

    private func enforceLimits() {
        reapBodiesIfNeeded()
        evictRowsIfNeeded()
    }

    private func reapBodiesIfNeeded() {
        guard retainedBytes > maxRetainedBytes else { return }
        reapBodies(downTo: maxRetainedBytes)
    }

    /// Release the oldest bodies while keeping their rows. `reapCursor` only moves forward,
    /// so this stays O(rows actually reaped) rather than rescanning the history each time.
    private func reapBodies(downTo target: Int) {
        while retainedBytes > target {
            let pos = reapCursor - evictedCount
            // Never reap the newest row: it is the one most likely to be on screen.
            guard exchanges.indices.contains(pos), pos < exchanges.count - 1 else { break }
            let freed = exchanges[pos].releaseBodies()
            retainedBytes -= freed
            reapCursor += 1
        }
    }

    // MARK: Memory pressure

    /// Holding a large body cache makes this app a good citizen only if it gives the cache
    /// back when the system asks. Releasing our own references is not enough on its own:
    /// the allocator keeps large freed blocks on its free list, so the footprint stays high
    /// until we explicitly ask it to return them.
    private func startMemoryPressureWatch() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.relieveMemoryPressure() }
        }
        src.resume()
        memoryPressure = src
    }

    private func relieveMemoryPressure() {
        let before = retainedBytes
        reapBodies(downTo: maxRetainedBytes / 4)
        malloc_zone_pressure_relief(nil, 0)
        needsRefilter = true
        if before > retainedBytes {
            statusLine = "Released \(ByteCountFormatter.string(fromByteCount: Int64(before - retainedBytes), countStyle: .memory)) of cached bodies under memory pressure"
        }
    }

    private func evictRowsIfNeeded() {
        guard exchanges.count > maxExchanges + evictChunk else { return }
        let drop = exchanges.count - maxExchanges
        for e in exchanges.prefix(drop) {
            index.removeValue(forKey: e.id)
            retainedBytes -= e.retainedBytes
        }
        exchanges.removeFirst(drop)
        evictedCount += drop
        droppedCount += drop
        reapCursor = max(reapCursor, evictedCount)
    }

    // MARK: Filtering + timeline

    /// Rows the table may show right now. `nil` means no limit.
    private var rowWindow: Int? {
        if showAllRows { return nil }
        // The window exists to bound the *delta* AppKit has to animate while rows stream in.
        // Paused, nothing is streaming, so there is no reason to hide history.
        return isRecording ? maxLiveRows : nil
    }

    private func rebuildVisible() {
        let q = filterText.lowercased()
        let deep = deepSearch
        let matches: [Exchange]
        if q.isEmpty {
            matches = exchanges
        } else {
            // `searchKey` is precomputed and already lowercased; this is one substring scan
            // per row instead of four fresh String allocations.
            matches = exchanges.filter { $0.matches(q, deep: deep) }
        }

        let now = Date()
        if now.timeIntervalSince(lastTimelineRebuild) >= Self.timelineInterval {
            lastTimelineRebuild = now
            rebuildTimeline(from: matches)
        }

        let scoped = selectedRange.map { range in matches.filter { range.contains($0.startedAt) } } ?? matches
        matchCount = scoped.count

        let rows: [Exchange]
        if let limit = rowWindow, scoped.count > limit {
            rows = Array(scoped.suffix(limit))
            withheldCount = scoped.count - limit
        } else {
            rows = scoped
            withheldCount = 0
        }

        // Animating a large row delta is what pins AppKit inside `endUpdates`; these are
        // data updates, not gestures, so there is nothing to animate.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { visible = rows }
    }

    private func rebuildTimeline(from source: [Exchange]) {
        guard let first = source.first, let last = source.last else {
            timeline = []; timelineSpan = nil; return
        }
        let start = first.startedAt
        // A live capture's newest event is "now"-ish; extend so the strip does not jitter.
        let end = max(last.startedAt, start.addingTimeInterval(1))
        let span = end.timeIntervalSince(start)
        let width = max(0.05, span / Double(Self.timelineBuckets))
        let count = max(1, min(Self.timelineBuckets, Int((span / width).rounded(.up))))

        var buckets = (0..<count).map { TimelineBucket(index: $0, start: start.addingTimeInterval(Double($0) * width)) }
        for e in source {
            let offset = e.startedAt.timeIntervalSince(start)
            let i = min(count - 1, max(0, Int(offset / width)))
            switch e.state {
            case .failed:
                buckets[i].error += 1
            case .pending, .responded:
                buckets[i].pending += 1
            case .complete:
                switch e.status ?? 0 {
                case 500...:      buckets[i].error += 1
                case 400..<500:   buckets[i].warn += 1
                default:          buckets[i].ok += 1
                }
            }
        }
        timeline = buckets
        timelineSpan = start...end
    }
}
