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

/// Thin wrapper over `xcrun simctl` for listing simulators/apps and launching with the hook injected.
enum SimulatorService {
    static func run(_ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = args
        let out = Pipe(); let errPipe = Pipe()
        p.standardOutput = out; p.standardError = errPipe
        try p.run(); p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if p.terminationStatus != 0 {
            let e = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "simctl", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: e])
        }
        return data
    }

    static func bootedDevices() -> [SimDevice] {
        guard let data = try? run(["simctl", "list", "devices", "booted", "-j"]),
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
    static func installedApps(_ udid: String, includeSystem: Bool = false) -> [SimApp] {
        guard let data = try? run(["simctl", "listapps", udid]) else { return [] }
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
    static func launch(app: SimApp, on udid: String, dylibPath: String, socketPath: String) throws -> Int32 {
        var env = ProcessInfo.processInfo.environment
        env["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = dylibPath
        env["SIMCTL_CHILD_SNOOPY_SOCKET"] = socketPath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["simctl", "launch", "--terminate-running-process", udid, app.bundleId]
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run(); p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Output form: "<bundleId>: <pid>"
        if let pidStr = text.split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr) { return pid }
        return 0
    }

    static func terminate(app: SimApp, on udid: String) {
        _ = try? run(["simctl", "terminate", udid, app.bundleId])
    }
}
