import Foundation
import SwiftUI
import SnoopyCore
import SnoopyIPC

/// Holds captured exchanges and applies hook events. UI-facing; mutated on the main actor.
@MainActor
final class CaptureStore: ObservableObject {
    @Published private(set) var exchanges: [Exchange] = []   // newest last
    @Published var isPaused = false
    @Published var connectedProcesses: [Int32: String] = [:]
    @Published var statusLine: String = "Idle"

    private var index: [String: Int] = [:]   // id -> position in `exchanges`
    private let maxExchanges = 20_000

    // Batched apply: events queued off-main, flushed at ~30 Hz.
    private var pending: [HookEvent] = []
    private let lock = NSLock()
    private var flushScheduled = false

    /// Called from the socket's background threads.
    nonisolated func enqueue(_ event: HookEvent) {
        Task { @MainActor in self.applyBatched(event) }
    }

    private func applyBatched(_ event: HookEvent) {
        lock.lock(); pending.append(event); lock.unlock()
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        lock.lock(); let batch = pending; pending.removeAll(keepingCapacity: true); lock.unlock()
        for e in batch { apply(e) }
    }

    func clear() {
        exchanges.removeAll(); index.removeAll()
    }

    private func upsert(_ id: String, _ mutate: (inout Exchange) -> Void) {
        if let pos = index[id] {
            mutate(&exchanges[pos])
        } else {
            var e = Exchange(id: id)
            mutate(&e)
            exchanges.append(e)
            index[id] = exchanges.count - 1
            if exchanges.count > maxExchanges { evictOldest() }
        }
    }
    private func evictOldest() {
        let drop = exchanges.count - maxExchanges
        guard drop > 0 else { return }
        let removed = exchanges.prefix(drop)
        for e in removed { index[e.id] = nil }
        exchanges.removeFirst(drop)
        for (i, e) in exchanges.enumerated() { index[e.id] = i }
    }

    private func apply(_ event: HookEvent) {
        switch event {
        case .hello(let pid, let process, _):
            connectedProcesses[pid] = process
            statusLine = "Capturing \(process) (pid \(pid))"
        case .log:
            break
        case .request(let r):
            if isPaused { return }
            upsert(r.id) { e in
                e.taskId = r.taskId
                e.method = r.method
                e.urlString = r.url
                e.url = URL(string: r.url)
                e.requestHeaders = r.headers
                e.requestBody = r.body
                e.requestBodySize = r.bodySize
                e.requestBodyTruncated = r.bodyTruncated
                e.requestBodyOmitted = r.bodyOmitted
                e.startedAt = Date(timeIntervalSince1970: r.t)
                e.state = .pending
            }
        case .response(let r):
            upsert(r.id) { e in
                e.status = r.status
                e.mimeType = r.mimeType
                if !r.headers.isEmpty { e.responseHeaders = r.headers }
                e.respondedAt = Date(timeIntervalSince1970: r.t)
                if e.state == .pending { e.state = .responded }
            }
        case .metrics(let id, let timing):
            upsert(id) { $0.metrics = timing }
        case .complete(let c):
            upsert(c.id) { e in
                if let s = c.status { e.status = s }
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
        }
    }
}
