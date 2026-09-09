import Foundation
import Combine

@MainActor
final class Net: ObservableObject {
    @Published var log: [String] = []
    let base = "https://httpbin.org"

    func note(_ s: String) { log.append(s); if log.count > 40 { log.removeFirst() } }

    func runAll() { getJSON(); postJSON(); image(); notFound(); delegateStream() }

    func getJSON() {
        Task {
            do {
                let (d, r) = try await URLSession.shared.data(from: URL(string: "\(base)/get?src=snoopy")!)
                note("GET \((r as? HTTPURLResponse)?.statusCode ?? 0) \(d.count)B")
            } catch { note("GET err \(error.localizedDescription)") }
        }
    }
    func postJSON() {
        var req = URLRequest(url: URL(string: "\(base)/post")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer test-token-123", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["user": "sameer", "lesson": 42, "correct": true])
        URLSession.shared.dataTask(with: req) { [weak self] d, r, e in
            Task { @MainActor in self?.note("POST \((r as? HTTPURLResponse)?.statusCode ?? 0) \(d?.count ?? 0)B") }
        }.resume()
    }
    func image() {
        URLSession.shared.dataTask(with: URL(string: "\(base)/image/png")!) { [weak self] d, r, e in
            Task { @MainActor in self?.note("IMG \((r as? HTTPURLResponse)?.statusCode ?? 0) \(d?.count ?? 0)B") }
        }.resume()
    }
    func notFound() {
        URLSession.shared.dataTask(with: URL(string: "\(base)/status/404")!) { [weak self] _, r, _ in
            Task { @MainActor in self?.note("404 -> \((r as? HTTPURLResponse)?.statusCode ?? 0)") }
        }.resume()
    }
    func delegateStream() {
        let d = StreamDelegate { [weak self] status, bytes in
            Task { @MainActor in self?.note("STREAM \(status) \(bytes)B") }
        }
        let s = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        s.dataTask(with: URL(string: "\(base)/stream/5")!).resume()
    }
}

final class StreamDelegate: NSObject, URLSessionDataDelegate {
    let done: (Int, Int) -> Void
    var bytes = 0
    var status = 0
    init(_ done: @escaping (Int, Int) -> Void) { self.done = done }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive r: URLResponse) async -> URLSession.ResponseDisposition {
        status = (r as? HTTPURLResponse)?.statusCode ?? 0; return .allow
    }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { bytes += data.count }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) { done(status, bytes) }
}
