import Foundation

struct SimDevice: Identifiable, Hashable {
    let udid: String
    let name: String
    let runtime: String
    var id: String { udid }
}
struct SimApp: Identifiable, Hashable {
    let bundleId: String
    let name: String
    let path: String
    var id: String { bundleId }
}

/// Thin wrapper over `xcrun simctl` for listing simulators/apps and launching with the hook
/// injected.
///
/// Every entry point is `async` and runs the child process off the main thread. They used to
/// be synchronous and were called from `AppController.init`, so launching Snoopy blocked the
/// main actor inside `Process.waitUntilExit()` for as long as CoreSimulator took to answer —
/// routinely one to three seconds on a cold boot, during which the window did not draw.
enum SimulatorService {
    /// Runs `xcrun` on a background queue. `Process` writes into a pipe with a finite buffer,
    /// so the output must be drained while the child runs; reading only after `waitUntilExit`
    /// deadlocks as soon as a child produces more than the pipe buffer (`simctl listapps` on
    /// a device with many apps does exactly that).
    static func run(_ args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try runSync(args)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func runSync(_ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = args
        let out = Pipe(), errPipe = Pipe()
        p.standardOutput = out; p.standardError = errPipe

        var outData = Data(), errData = Data()
        let lock = NSLock()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock(); outData.append(d); lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock(); errData.append(d); lock.unlock()
        }

        try p.run()
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        outData.append(out.fileHandleForReading.readDataToEndOfFile())
        errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        let (o, e) = (outData, errData)
        lock.unlock()

        if p.terminationStatus != 0 {
            let msg = String(data: e, encoding: .utf8) ?? "xcrun \(args.joined(separator: " ")) failed"
            throw NSError(domain: "simctl", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return o
    }

    static func bootedDevices() async -> [SimDevice] {
        guard let data = try? await run(["simctl", "list", "devices", "booted", "-j"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else { return [] }
        var result: [SimDevice] = []
        for (runtime, devs) in byRuntime {
            let rt = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            for d in devs where (d["state"] as? String) == "Booted" {
                if let udid = d["udid"] as? String, let name = d["name"] as? String {
                    result.append(SimDevice(udid: udid, name: name, runtime: rt))
                }
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Installed, user-facing apps (filters out Apple system apps by default).
    static func installedApps(_ udid: String, includeSystem: Bool = false) async -> [SimApp] {
        guard let data = try? await run(["simctl", "listapps", udid]) else { return [] }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return [] }
        var apps: [SimApp] = []
        for (bundleId, info) in plist {
            guard let info = info as? [String: Any] else { continue }
            let type = info["ApplicationType"] as? String ?? ""
            if !includeSystem && type != "User" { continue }
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleId
            let path = (info["Path"] as? String) ?? (info["Bundle"] as? String) ?? ""
            apps.append(SimApp(bundleId: bundleId, name: name, path: path))
        }
        return apps.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Launches an installed app with the hook injected. Returns the child pid.
    @discardableResult
    static func launch(app: SimApp, on udid: String, dylibPath: String, socketPath: String) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var env = ProcessInfo.processInfo.environment
                env["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = dylibPath
                env["SIMCTL_CHILD_SNOOPY_SOCKET"] = socketPath
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                p.arguments = ["simctl", "launch", "--terminate-running-process", udid, app.bundleId]
                p.environment = env
                let out = Pipe(); p.standardOutput = out; p.standardError = out
                do {
                    try p.run()
                    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    p.waitUntilExit()
                    // Output form: "<bundleId>: <pid>"
                    if let pidStr = text.split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines),
                       let pid = Int32(pidStr) {
                        continuation.resume(returning: pid)
                    } else if p.terminationStatus != 0 {
                        continuation.resume(throwing: NSError(
                            domain: "simctl", code: Int(p.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: text.trimmingCharacters(in: .whitespacesAndNewlines)]))
                    } else {
                        continuation.resume(returning: 0)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func terminate(app: SimApp, on udid: String) async {
        _ = try? await run(["simctl", "terminate", udid, app.bundleId])
    }
}
