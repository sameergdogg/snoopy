import Foundation
import SnoopyIPC
import SnoopyCore
import Darwin

/// Listens on a Unix domain socket for hook connections and emits decoded events.
/// Each connected process gets its own reader thread; events are delivered on `onEvent`
/// (called on an arbitrary background queue — hop to main in the handler).
final class SocketServer {
    let socketPath: String
    var onEvent: ((CaptureEvent) -> Void)?

    private var listenFD: Int32 = -1
    private let stateLock = NSLock()
    private var running = false
    private let acceptQueue = DispatchQueue(label: "dev.snoopy.socket.accept")

    init(socketPath: String) { self.socketPath = socketPath }

    deinit { stop() }

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    func start() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw err("socket") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { close(fd); throw err("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bound == 0 else { close(fd); throw err("bind") }
        guard listen(fd, 16) == 0 else { close(fd); throw err("listen") }
        listenFD = fd
        stateLock.lock(); running = true; stateLock.unlock()
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    /// Idempotent, and now actually called — from `AppController`'s deinit and on app
    /// termination. Nothing used to call it, so every run of Snoopy left its socket behind
    /// in /tmp and the listening fd open until the process died.
    func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()
        guard wasRunning else { return }
        // Shutdown first: closing alone can leave a blocked `accept` parked on a stale fd,
        // whereas shutdown wakes it so the loop observes `running == false` and exits.
        shutdown(fd, SHUT_RDWR)
        if fd >= 0 { close(fd) }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while isRunning {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                // Previously this slept and retried unconditionally, so once the listening
                // fd was closed the loop spun at ~100 Hz forever instead of finishing.
                guard isRunning, errno == EINTR || errno == EAGAIN || errno == ECONNABORTED else { break }
                usleep(10_000)
                continue
            }
            let readQueue = DispatchQueue(label: "dev.snoopy.socket.read.\(client)")
            readQueue.async { [weak self] in self?.readLoop(client) }
        }
    }

    private func readLoop(_ fd: Int32) {
        var parser = FrameParser()
        let bufSize = 64 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        // The pid this connection announced, so its departure can be reported. Without it
        // the UI listed every process that had ever attached and never removed any of them.
        var connectedPID: Int32?
        defer {
            buf.deallocate()
            close(fd)
            if let pid = connectedPID { onEvent?(.detached(pid: pid)) }
        }
        while isRunning {
            let n = read(fd, buf, bufSize)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                break
            }
            // This loop never returns, so the pool GCD installs around the block never
            // drains. `JSONSerialization` hands back autoreleased NSString/NSData — for a
            // capture with large bodies that accumulates gigabytes of reachable-but-dead
            // memory, which reads as a runaway leak and pushes the machine into swap.
            autoreleasepool {
                let chunk = Data(bytes: buf, count: n)
                for obj in parser.append(chunk) {
                    guard let event = HookEventDecoder.decode(obj) else { continue }
                    if case .hello(let pid, _, _) = event { connectedPID = pid }
                    onEvent?(event.captureEvent)
                }
            }
        }
    }

    private func err(_ op: String) -> NSError {
        NSError(domain: "SocketServer", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(op) failed: \(String(cString: strerror(errno)))"])
    }
}
