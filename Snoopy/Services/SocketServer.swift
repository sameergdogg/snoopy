import Foundation
import SnoopyIPC
import Darwin

/// Listens on a Unix domain socket for hook connections and emits decoded events.
/// Each connected process gets its own reader thread; events are delivered on `onEvent`
/// (called on an arbitrary background queue — hop to main in the handler).
final class SocketServer {
    let socketPath: String
    var onEvent: ((HookEvent) -> Void)?
    private var listenFD: Int32 = -1
    private var running = false
    private let acceptQueue = DispatchQueue(label: "dev.snoopy.socket.accept")

    init(socketPath: String) { self.socketPath = socketPath }

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
        running = true
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while running {
            let client = accept(listenFD, nil, nil)
            if client < 0 { if running { usleep(10_000); continue } else { break } }
            let readQueue = DispatchQueue(label: "dev.snoopy.socket.read.\(client)")
            readQueue.async { [weak self] in self?.readLoop(client) }
        }
    }

    private func readLoop(_ fd: Int32) {
        var parser = FrameParser()
        let bufSize = 64 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate(); close(fd) }
        while running {
            let n = read(fd, buf, bufSize)
            if n <= 0 { break }
            // This loop never returns, so the pool GCD installs around the block never
            // drains. `JSONSerialization` hands back autoreleased NSString/NSData — for a
            // capture with large bodies that accumulates gigabytes of reachable-but-dead
            // memory, which reads as a runaway leak and pushes the machine into swap.
            autoreleasepool {
                let chunk = Data(bytes: buf, count: n)
                for obj in parser.append(chunk) {
                    if let event = HookEventDecoder.decode(obj) { onEvent?(event) }
                }
            }
        }
    }

    private func err(_ op: String) -> NSError {
        NSError(domain: "SocketServer", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(op) failed: \(String(cString: strerror(errno)))"])
    }
}
