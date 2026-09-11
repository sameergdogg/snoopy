import Foundation
import SwiftUI
import SnoopyCore
import SnoopyIPC
import Darwin

/// One column of the timeline strip: how many exchanges started in this slice, by outcome.
struct TimelineBucket: Identifiable, Equatable {
    let index: Int
    var start: Date
    var ok = 0
    var warn = 0
    var error = 0
    var pending = 0

    var id: Int { index }
    var total: Int { ok + warn + error + pending }
}

/// Lock-protected handoff between the socket's reader threads and the main actor.
private final class EventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HookEvent] = []

    func push(_ event: HookEvent) {
        lock.lock(); items.append(event); lock.unlock()
    }
    func drain() -> [HookEvent] {
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
@MainActor
final class CaptureStore: ObservableObject {
    // Published surface. `exchanges` is deliberately *not* published: republishing the whole
    // history on every mutation is what made the table re-diff thousands of rows per event.
    @Published private(set) var visible: [Exchange] = []
    @Published private(set) var timeline: [TimelineBucket] = []
    @Published private(set) var timelineSpan: ClosedRange<Date>?
    @Published private(set) var totalCount = 0
    /// How many rows match the filter and time range, before the display cap below.
    @Published private(set) var matchCount = 0
    @Published private(set) var retainedBytes = 0
    @Published private(set) var droppedCount = 0

    @Published var isPaused = false
    @Published var connectedProcesses: [Int32: String] = [:]
    @Published var statusLine: String = "Idle"

    @Published var filterText: String = "" {
        didSet { guard oldValue != filterText else { return }; needsRefilter = true; forcePublish = true }
    }
    /// Time range brushed on the timeline, or nil for "everything".
    @Published var selectedRange: ClosedRange<Date>? {
        didSet { guard oldValue != selectedRange else { return }; needsRefilter = true; forcePublish = true }
    }

    private(set) var exchanges: [Exchange] = []   // newest last, full retained history

    // MARK: Limits

    /// Rows kept before the oldest are dropped entirely.
    private let maxExchanges = 10_000
    /// Body bytes kept before the oldest bodies are released (rows survive).
    private let maxRetainedBytes = 256 * 1024 * 1024
    /// Rows are evicted in chunks so the array memmove amortises instead of running per event.
    private let evictChunk = 512
    /// Hard cap on rows handed to the SwiftUI `Table`.
    ///
    /// `Table` turns a row-set change into an `NSTableView` batch update, and a delta of a
    /// few thousand rows wedges AppKit inside `endUpdates` for minutes at 100% CPU — clearing
    /// a timeline brush over a long capture was enough to hang the app outright. Full history
    /// is still kept in `exchanges` for the timeline, filtering and HAR export; the table just
    /// shows the newest slice of whatever matches.
    private let maxVisibleRows = 1_000

    // MARK: Indexing

    private var index: [String: Int] = [:]   // id -> absolute position
    private var evictedCount = 0             // absolute position of exchanges[0]
    private var reapCursor = 0               // absolute position of the oldest un-reaped body

    // MARK: Batching

    private let inbox = EventInbox()
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

    init() {
        startPump()
        startMemoryPressureWatch()
    }

    /// Called from the socket's background threads. Deliberately does no main-actor work:
    /// hopping to the main actor once per event is what saturated the run loop under load.
    /// The pump below picks events up on the next tick.
    nonisolated func enqueue(_ event: HookEvent) {
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
    /// filter, brushing the timeline) bypass this via `forcePublish`.
    private var publishInterval: Double {
        switch exchanges.count {
        case ..<2_000:  return 0.033   // ~30 Hz
        case ..<10_000: return 0.1     // ~10 Hz
        default:        return 0.2     // ~5 Hz
        }
    }

    func clear() {
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
        lastTimelineRebuild = .distantPast
    }

    /// O(1) lookup for the detail pane. A linear scan here ran on every render.
    func exchange(id: Exchange.ID) -> Exchange? {
        guard let abs = index[id] else { return nil }
        let pos = abs - evictedCount
        guard exchanges.indices.contains(pos) else { return nil }
        return exchanges[pos]
    }

    // MARK: Apply

    /// Returns true when the exchange list changed in a way the UI must see.
    private func apply(_ event: HookEvent) -> Bool {
        switch event {
        case .hello(let pid, let process, _):
            connectedProcesses[pid] = process
            statusLine = "Capturing \(process) (pid \(pid))"
            return false
        case .log:
            return false
        case .request(let r):
            if isPaused { return false }
            upsert(r.id) { e in
                e.taskId = r.taskId
                e.setRequestLine(method: r.method, urlString: r.url)
                e.requestHeaders = r.headers
                e.requestBody = r.body
                e.requestBodySize = r.bodySize
                e.requestBodyTruncated = r.bodyTruncated
                e.requestBodyOmitted = r.bodyOmitted
                e.setStartedAt(Date(timeIntervalSince1970: r.t))
                e.state = .pending
            }
            return true
        case .response(let r):
            upsert(r.id) { e in
                e.setStatus(r.status)
                e.mimeType = r.mimeType
                if !r.headers.isEmpty { e.responseHeaders = r.headers }
                e.respondedAt = Date(timeIntervalSince1970: r.t)
                if e.state == .pending { e.state = .responded }
            }
            return true
        case .metrics(let id, let timing):
            upsert(id) { $0.metrics = timing }
            return true
        case .complete(let c):
            upsert(c.id) { e in
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
            }
            return true
        }
    }

    private func upsert(_ id: String, _ mutate: (inout Exchange) -> Void) {
        if let abs = index[id] {
            let pos = abs - evictedCount
            guard exchanges.indices.contains(pos) else { return }   // already evicted
            let before = exchanges[pos].retainedBytes
            mutate(&exchanges[pos])
            retainedBytes += exchanges[pos].retainedBytes - before
        } else {
            var e = Exchange(id: id)
            mutate(&e)
            exchanges.append(e)
            index[id] = evictedCount + exchanges.count - 1
            retainedBytes += e.retainedBytes
        }
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

    private func rebuildVisible() {
        let q = filterText.lowercased()
        let matches: [Exchange]
        if q.isEmpty {
            matches = exchanges
        } else {
            // `searchKey` is precomputed and already lowercased; this is one substring scan
            // per row instead of four fresh String allocations.
            matches = exchanges.filter { $0.searchKey.contains(q) }
        }

        let now = Date()
        if now.timeIntervalSince(lastTimelineRebuild) >= Self.timelineInterval {
            lastTimelineRebuild = now
            rebuildTimeline(from: matches)
        }

        let scoped = selectedRange.map { range in matches.filter { range.contains($0.startedAt) } } ?? matches
        matchCount = scoped.count
        let rows = scoped.count > maxVisibleRows ? Array(scoped.suffix(maxVisibleRows)) : scoped

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
