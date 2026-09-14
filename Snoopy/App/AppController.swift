import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SnoopyCore

/// A non-fatal problem worth telling the user about, shown as a dismissible banner.
struct Notice: Identifiable, Equatable {
    enum Level { case info, warning, error }
    let id = UUID()
    let level: Level
    let text: String
}

/// Owns the socket server, simulator list, and launch flow; bridges hook events into the store.
@MainActor
final class AppController: ObservableObject {
    let store = CaptureStore()

    @Published var devices: [SimDevice] = []
    @Published var selectedDevice: SimDevice? { didSet { if oldValue != selectedDevice { Task { await refreshApps() } } } }
    @Published var apps: [SimApp] = []
    @Published var selectedApp: SimApp?
    @Published var notice: Notice?

    @Published private(set) var isLoadingDevices = false
    @Published private(set) var isLoadingApps = false
    @Published private(set) var isLaunching = false

    private var server: SocketServer?
    private var deviceWatch: Task<Void, Never>?
    let socketPath: String
    let dylibPath: String?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Snoopy", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        // Short path required: AF_UNIX sun_path is ~104 bytes.
        self.socketPath = "/tmp/snoopy-\(getpid()).sock"
        self.dylibPath = Bundle.main.url(forResource: "libSnoopyHook", withExtension: "dylib")?.path
        AppController.sweepStaleSockets(keeping: socketPath)
        startServer()
        // Deliberately not awaited here: this used to call simctl synchronously from `init`,
        // so the window did not appear until CoreSimulator answered.
        Task { await refreshDevices() }
        startDeviceWatch()
    }

    deinit {
        deviceWatch?.cancel()
        server?.stop()
    }

    /// Called from `applicationWillTerminate`; `deinit` is not guaranteed to run for an
    /// object the app holds for its whole lifetime.
    func shutdown() {
        deviceWatch?.cancel()
        server?.stop()
        server = nil
    }

    /// Removes `/tmp/snoopy-<pid>.sock` entries whose process is gone.
    ///
    /// A clean quit unlinks its own socket, but a crash or a `kill -9` cannot, so these
    /// accumulated in /tmp indefinitely — one per run that ever ended badly.
    private static func sweepStaleSockets(keeping current: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/tmp") else { return }
        for name in entries where name.hasPrefix("snoopy-") && name.hasSuffix(".sock") {
            let path = "/tmp/" + name
            guard path != current else { continue }
            let digits = name.dropFirst("snoopy-".count).dropLast(".sock".count)
            guard let pid = pid_t(digits) else { continue }
            // ESRCH means no such process; anything else means it is alive, or not ours to judge.
            if kill(pid, 0) != 0, errno == ESRCH {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    private func startServer() {
        let s = SocketServer(socketPath: socketPath)
        s.onEvent = { [weak self] event in self?.store.enqueue(event) }
        do { try s.start(); server = s }
        catch { notice = Notice(level: .error, text: "Could not open the capture socket: \(error.localizedDescription)") }
    }

    // MARK: Simulators

    /// Booting a simulator after Snoopy started used to require noticing that the list was
    /// stale and clicking Refresh. Polling is cheap next to a `simctl` call the user makes
    /// by hand, and it only runs while the window is up.
    private func startDeviceWatch() {
        deviceWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                guard let self, !Task.isCancelled else { return }
                // Each poll spawns `xcrun`, so it runs only when the user can actually see
                // the result, and never on top of a refresh or launch already in progress.
                guard NSApp.isActive, !self.isLoadingDevices, !self.isLaunching else { continue }
                let fresh = await SimulatorService.bootedDevices()
                guard !Task.isCancelled else { return }
                if fresh != self.devices { self.applyDevices(fresh) }
            }
        }
    }

    func refreshDevices() async {
        isLoadingDevices = true
        let found = await SimulatorService.bootedDevices()
        isLoadingDevices = false
        applyDevices(found)
    }

    private func applyDevices(_ found: [SimDevice]) {
        devices = found
        if let d = selectedDevice, !found.contains(d) { selectedDevice = found.first }
        else if selectedDevice == nil { selectedDevice = found.first }
        else { Task { await refreshApps() } }
    }

    func refreshApps() async {
        guard let d = selectedDevice else { apps = []; selectedApp = nil; return }
        isLoadingApps = true
        let found = await SimulatorService.installedApps(d.udid)
        isLoadingApps = false
        apps = found
        if let a = selectedApp, !found.contains(a) { selectedApp = nil }
    }

    func launchSelected() async {
        guard let d = selectedDevice, let app = selectedApp else {
            notice = Notice(level: .info, text: "Pick a booted simulator and an app first.")
            return
        }
        guard let dylib = dylibPath else {
            notice = Notice(level: .error, text: "libSnoopyHook.dylib is missing from the app bundle — rebuild Snoopy.")
            return
        }
        // Launching with capture off would silently drop everything the app does on startup,
        // which is usually the traffic you opened Snoopy to see.
        if !store.isRecording { store.startRecording() }
        isLaunching = true
        store.statusLine = "Launching \(app.name)…"
        defer { isLaunching = false }
        do {
            let pid = try await SimulatorService.launch(app: app, on: d.udid, dylibPath: dylib, socketPath: socketPath)
            store.statusLine = pid > 0
                ? "Launched \(app.name) (pid \(pid)) — waiting for traffic…"
                : "Launched \(app.name) — waiting for traffic…"
        } catch {
            notice = Notice(level: .error, text: "Launch failed: \(error.localizedDescription)")
            store.statusLine = "Launch failed"
        }
    }

    // MARK: Xcode hand-off

    /// The env var a user pastes into an Xcode scheme to capture Xcode-launched runs.
    var xcodeEnvHint: String {
        let dylib = dylibPath ?? "<path-to>/libSnoopyHook.dylib"
        return "DYLD_INSERT_LIBRARIES=\(dylib)\nSNOOPY_SOCKET=\(socketPath)"
    }

    func copyXcodeHint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(xcodeEnvHint, forType: .string)
        notice = Notice(level: .info, text: "Copied — paste into Scheme → Run → Environment Variables.")
    }

    // MARK: Export / session files

    func exportHAR() {
        guard !store.exchanges.isEmpty else {
            notice = Notice(level: .info, text: "Nothing captured yet.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "snoopy-session.har"
        panel.allowedContentTypes = [UTType.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HARExport.data(from: store.exchanges).write(to: url)
            notice = Notice(level: .info, text: "Exported \(store.exchanges.count.formatted()) exchanges.")
        } catch {
            notice = Notice(level: .error, text: "Export failed: \(error.localizedDescription)")
        }
    }

    func saveSession() {
        guard !store.exchanges.isEmpty else {
            notice = Notice(level: .info, text: "Nothing captured yet.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "capture.\(Session.fileExtension)"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows = store.exchanges
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) { try Session.encode(rows) }.value
                try data.write(to: url)
                notice = Notice(level: .info, text: "Saved \(rows.count.formatted()) exchanges.")
            } catch {
                notice = Notice(level: .error, text: "Save failed: \(error.localizedDescription)")
            }
        }
    }

    func openSession() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try Data(contentsOf: url)
                let rows = try await Task.detached(priority: .userInitiated) { try Session.decode(data) }.value
                store.load(rows)
            } catch {
                notice = Notice(level: .error, text: "Could not open that session: \(error.localizedDescription)")
            }
        }
    }
}
