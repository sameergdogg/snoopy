import XCTest
@testable import SnoopyCore

/// The store's semantics, which were previously unreachable from a test because it lived in
/// the app target behind `@MainActor` and a `SwiftUI` dependency. The pause bug below
/// shipped precisely because nothing could assert on it.
@MainActor
final class CaptureStoreTests: XCTestCase {

    private func makeStore() -> CaptureStore {
        // `pumped: false` so nothing depends on a timer firing.
        CaptureStore(pumped: false)
    }

    private func request(_ id: String, at t: Double = 1_000, url: String = "https://api.example.com/a") -> CaptureEvent {
        .request(.init(id: id, t: t, method: "GET", url: url))
    }
    private func complete(_ id: String, status: Int = 200, at t: Double = 1_001, body: Data? = nil) -> CaptureEvent {
        .complete(.init(id: id, t: t, status: status, body: body, bodySize: body?.count))
    }

    private func feed(_ store: CaptureStore, _ events: [CaptureEvent]) {
        for e in events { store.enqueue(e) }
        store.flush()
    }

    // MARK: Pause

    /// The bug: `.request` was gated on the pause flag but `.response`/`.metrics`/
    /// `.complete` were not, and they went through an *upsert*. Every response that
    /// arrived while paused therefore created a row from nothing — method "GET", no URL,
    /// no host, and a start time of whenever the response landed rather than the request.
    func testPausedCaptureCreatesNoPhantomRows() {
        let store = makeStore()
        store.pauseRecording()

        feed(store, [request("a"), complete("a"), .response(.init(id: "b", t: 1_002, status: 500))])

        XCTAssertEqual(store.exchanges.count, 0, "a paused capture must not invent rows")
        XCTAssertEqual(store.totalCount, 0)
    }

    /// Late events for an exchange that was never opened are meaningless — there is no
    /// method, URL or start time to show — so they are dropped in every state, not just
    /// while paused.
    func testResponseWithoutRequestIsIgnoredWhileRecording() {
        let store = makeStore()
        feed(store, [.response(.init(id: "ghost", t: 1_000, status: 200)),
                     complete("ghost"),
                     .metrics(id: "ghost", timing: Timing())])
        XCTAssertEqual(store.exchanges.count, 0)
    }

    /// Pausing must not strand a request that was already in flight: it keeps updating to
    /// completion, otherwise it would sit as "pending" forever.
    func testInFlightExchangeStillCompletesAfterPause() {
        let store = makeStore()
        feed(store, [request("a")])
        XCTAssertEqual(store.exchanges.first?.state, .pending)

        store.pauseRecording()
        feed(store, [complete("a", status: 204)])

        XCTAssertEqual(store.exchanges.count, 1)
        XCTAssertEqual(store.exchanges.first?.state, .complete)
        XCTAssertEqual(store.exchanges.first?.status, 204)
    }

    func testResumingAcceptsNewRequestsAgain() {
        let store = makeStore()
        store.pauseRecording()
        feed(store, [request("a")])
        XCTAssertEqual(store.exchanges.count, 0)

        store.startRecording()
        feed(store, [request("b")])
        XCTAssertEqual(store.exchanges.count, 1)
        XCTAssertEqual(store.exchanges.first?.id, "b")
    }

    /// Resuming republishes even when no event follows. Without this the row window stayed
    /// at its paused size and nothing repainted, so on an idle app pressing Record looked
    /// like it had done nothing at all.
    func testRecordingToggleRepublishesImmediately() {
        let store = makeStore()
        store.maxLiveRows = 2
        feed(store, [request("a"), request("b"), request("c")])

        store.pauseRecording()
        XCTAssertEqual(store.visible.count, 3, "paused: the window is lifted, all rows visible")
        XCTAssertEqual(store.withheldCount, 0)

        store.startRecording()
        XCTAssertEqual(store.visible.count, 2, "recording: the window applies again")
        XCTAssertEqual(store.withheldCount, 1)
    }

    func testRecordingStateReflectsAttachment() {
        let store = makeStore()
        XCTAssertEqual(store.recordingState, .waiting)

        feed(store, [.attached(pid: 42, process: "Duolingo", bundleId: "com.duolingo.app")])
        XCTAssertEqual(store.recordingState, .recording)
        XCTAssertEqual(store.attached.map(\.pid), [42])

        store.pauseRecording()
        XCTAssertEqual(store.recordingState, .paused)

        store.startRecording()
        feed(store, [.detached(pid: 42)])
        XCTAssertEqual(store.attached.count, 0, "a process that goes away must leave the list")
        XCTAssertEqual(store.recordingState, .waiting)
    }

    // MARK: Row window

    func testWindowAppliesOnlyWhileRecording() {
        let store = makeStore()
        store.maxLiveRows = 10
        feed(store, (0..<50).map { request("r\($0)", at: 1_000 + Double($0)) })

        XCTAssertEqual(store.visible.count, 10)
        XCTAssertEqual(store.withheldCount, 40)
        XCTAssertEqual(store.matchCount, 50, "the window hides rows, it does not discard them")
        XCTAssertEqual(store.visible.last?.id, "r49", "the window keeps the newest")

        store.pauseRecording()
        XCTAssertEqual(store.visible.count, 50, "a finished capture is fully scrollable")
    }

    func testShowAllRowsOverridesTheWindow() {
        let store = makeStore()
        store.maxLiveRows = 5
        feed(store, (0..<20).map { request("r\($0)", at: 1_000 + Double($0)) })
        XCTAssertEqual(store.visible.count, 5)

        store.showAllRows = true
        XCTAssertEqual(store.visible.count, 20)
        XCTAssertEqual(store.withheldCount, 0)
    }

    // MARK: Filtering

    func testFilterMatchesHostPathAndQuery() {
        let store = makeStore()
        feed(store, [request("a", url: "https://api.example.com/users/1"),
                     request("b", at: 1_001, url: "https://cdn.other.com/img.png?size=large")])

        store.filterText = "example"
        XCTAssertEqual(store.visible.map(\.id), ["a"])

        store.filterText = "size=large"
        XCTAssertEqual(store.visible.map(\.id), ["b"], "the query string is searchable")

        store.filterText = ""
        XCTAssertEqual(store.visible.count, 2)
    }

    func testDeepSearchCoversHeadersAndBodies() {
        let store = makeStore()
        let body = Data(#"{"displayName":"Zombie"}"#.utf8)
        feed(store, [request("a"), complete("a", body: body)])

        store.filterText = "zombie"
        XCTAssertEqual(store.visible.count, 0, "shallow search does not read bodies")

        store.deepSearch = true
        XCTAssertEqual(store.visible.map(\.id), ["a"])

        store.deepSearch = false
        XCTAssertEqual(store.visible.count, 0)
        XCTAssertNil(store.exchanges.first?.deepSearchKey, "turning it off must release the index")
    }

    func testTimeRangeScopesRows() {
        let store = makeStore()
        feed(store, (0..<10).map { request("r\($0)", at: 1_000 + Double($0)) })

        store.selectedRange = Date(timeIntervalSince1970: 1_002)...Date(timeIntervalSince1970: 1_004)
        XCTAssertEqual(store.visible.map(\.id), ["r2", "r3", "r4"])

        store.selectedRange = nil
        XCTAssertEqual(store.visible.count, 10)
    }

    // MARK: Limits

    func testEvictionKeepsTheIdIndexConsistent() {
        let store = makeStore()
        store.maxExchanges = 100
        feed(store, (0..<2_000).map { request("r\($0)", at: 1_000 + Double($0)) })

        XCTAssertLessThanOrEqual(store.exchanges.count, 100 + 512)
        XCTAssertGreaterThan(store.droppedCount, 0)

        // The surviving newest row must still be reachable by id, and an evicted one must not
        // resolve to some other row's slot.
        let newest = store.exchanges.last!
        XCTAssertEqual(store.exchange(id: newest.id)?.id, newest.id)
        XCTAssertNil(store.exchange(id: "r0"))

        // And a late event for an evicted id must not resurrect or corrupt anything.
        let before = store.exchanges.count
        feed(store, [complete("r0", status: 500)])
        XCTAssertEqual(store.exchanges.count, before)
    }

    func testBodyReapingFreesBytesButKeepsRows() {
        let store = makeStore()
        store.maxRetainedBytes = 4_000
        let body = Data(repeating: 0x41, count: 1_000)
        for i in 0..<20 {
            feed(store, [request("r\(i)", at: 1_000 + Double(i)), complete("r\(i)", body: body)])
        }
        XCTAssertEqual(store.exchanges.count, 20, "rows survive reaping")
        XCTAssertLessThanOrEqual(store.retainedBytes, 4_000 + body.count)
        XCTAssertTrue(store.exchanges.first!.bodiesReaped)
        XCTAssertNil(store.exchanges.first!.responseBody)
        XCTAssertEqual(store.exchanges.first!.responseBodySize, body.count, "the size is still reportable")
        XCTAssertNotNil(store.exchanges.last!.responseBody, "the newest body is never reaped")
    }

    func testClearResetsEverything() {
        let store = makeStore()
        feed(store, [request("a"), complete("a", body: Data(repeating: 1, count: 100))])
        store.filterText = "a"
        store.clear()

        XCTAssertEqual(store.exchanges.count, 0)
        XCTAssertEqual(store.visible.count, 0)
        XCTAssertEqual(store.retainedBytes, 0)
        XCTAssertEqual(store.totalCount, 0)
        XCTAssertNil(store.selectedRange)
        XCTAssertNil(store.timelineSpan)
    }

    // MARK: Timeline

    func testTimelineBucketsByOutcome() {
        let store = makeStore()
        feed(store, [request("ok", at: 1_000), complete("ok", status: 200),
                     request("warn", at: 1_000), complete("warn", status: 404),
                     request("err", at: 1_000), complete("err", status: 503),
                     request("open", at: 1_000)])

        let totals = store.timeline.reduce(into: (ok: 0, warn: 0, error: 0, pending: 0)) {
            $0.ok += $1.ok; $0.warn += $1.warn; $0.error += $1.error; $0.pending += $1.pending
        }
        XCTAssertEqual(totals.ok, 1)
        XCTAssertEqual(totals.warn, 1)
        XCTAssertEqual(totals.error, 1)
        XCTAssertEqual(totals.pending, 1)
    }

    // MARK: Loading

    func testLoadReplacesCaptureAndPauses() {
        let store = makeStore()
        feed(store, [request("live")])

        var saved = Exchange(id: "s1", method: "POST", urlString: "https://x.test/y")
        saved.setStatus(201)
        store.load([saved])

        XCTAssertEqual(store.exchanges.map(\.id), ["s1"])
        XCTAssertFalse(store.isRecording, "loading a session must not keep overwriting it live")
        XCTAssertEqual(store.visible.map(\.id), ["s1"])
    }
}

/// SwiftUI skips a collection update when the new value compares equal to the old one, so
/// `Exchange`'s `==` is load-bearing for the request table, not just bookkeeping.
@MainActor
final class ExchangeIdentityTests: XCTestCase {

    /// The regression: a row whose response lands on a later tick than its request stayed
    /// frozen at "…" forever, because the updated array compared equal to the previous one.
    func testUpdatedRowDoesNotCompareEqualToItsEarlierSelf() {
        let store = CaptureStore(pumped: false)
        store.enqueue(.request(.init(id: "a", t: 1_000, method: "GET", url: "https://x.test/a")))
        store.flush()
        let asPending = store.visible[0]
        XCTAssertNil(asPending.status)

        store.enqueue(.complete(.init(id: "a", t: 1_001, status: 200, bodySize: 4_096)))
        store.flush()
        let asComplete = store.visible[0]

        XCTAssertEqual(asComplete.status, 200)
        XCTAssertNotEqual(asPending, asComplete,
                          "same id, changed contents — SwiftUI must see these as different")
        XCTAssertNotEqual([asPending], [asComplete],
                          "the array the Table is handed must differ too")
    }

    func testIdentityStillHoldsForUnchangedRows() {
        var e = Exchange(id: "a", method: "GET", urlString: "https://x.test/a")
        XCTAssertEqual(e, e)
        let copy = e
        e.bumpRevision()
        XCTAssertNotEqual(e, copy)
        XCTAssertEqual(e.id, copy.id, "identity is unchanged; only the revision moved")
    }

    /// Hashing by id alone stays valid because `==` is stricter than the hash. The store's
    /// id index relies on it.
    func testHashingRemainsIdBased() {
        var a = Exchange(id: "same", method: "GET", urlString: "https://x.test")
        let b = a
        a.bumpRevision()
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, b)
    }

    func testEveryMutatingEventBumpsTheRevision() {
        let store = CaptureStore(pumped: false)
        store.enqueue(.request(.init(id: "a", t: 1_000, method: "GET", url: "https://x.test/a")))
        store.flush()
        var last = store.exchanges[0].revision

        for event in [CaptureEvent.response(.init(id: "a", t: 1_001, status: 200)),
                      .metrics(id: "a", timing: Timing()),
                      .complete(.init(id: "a", t: 1_002, status: 200))] {
            store.enqueue(event)
            store.flush()
            let now = store.exchanges[0].revision
            XCTAssertGreaterThan(now, last, "\(event) must mark the row dirty")
            last = now
        }
    }
}
