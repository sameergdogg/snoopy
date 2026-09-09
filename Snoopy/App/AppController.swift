import Foundation
import SwiftUI
import AppKit
import SnoopyCore

/// Owns the socket server, simulator list, and launch flow; bridges hook events into the store.
@MainActor
final class AppController: ObservableObject {
    let store = CaptureStore()
    @Published var devices: [SimDevice] = []
    @Published var selectedDevice: SimDevice?
    @Published var apps: [SimApp] = []
    @Published var selectedApp: SimApp?
    @Published var lastError: String?

    private var server: SocketServer?
    let socketPath: String
    let dylibPath: String?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Snoopy", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        // Short path required: AF_UNIX sun_path is ~104 bytes.
        self.socketPath = "/tmp/snoopy-\(getpid()).sock"
        self.dylibPath = Bundle.main.url(forResource: "libSnoopyHook", withExtension: "dylib")?.path
        startServer()
        refreshDevices()
    }

    private func startServer() {
        let s = SocketServer(socketPath: socketPath)
        s.onEvent = { [weak self] event in self?.store.enqueue(event) }
        do { try s.start(); server = s }
        catch { lastError = "Socket: \(error.localizedDescription)" }
    }

    func refreshDevices() {
        devices = SimulatorService.bootedDevices()
        if selectedDevice == nil { selectedDevice = devices.first }
        if let d = selectedDevice, !devices.contains(d) { selectedDevice = devices.first }
        refreshApps()
    }

    func refreshApps() {
        guard let d = selectedDevice else { apps = []; return }
        apps = SimulatorService.installedApps(d.udid)
        if let a = selectedApp, !apps.contains(a) { selectedApp = nil }
    }

    func launchSelected() {
        guard let d = selectedDevice, let app = selectedApp else { lastError = "Select a simulator and app"; return }
        guard let dylib = dylibPath else { lastError = "Hook dylib missing from app bundle"; return }
        do {
            let pid = try SimulatorService.launch(app: app, on: d.udid, dylibPath: dylib, socketPath: socketPath)
            store.statusLine = "Launched \(app.name) (pid \(pid)) — waiting for traffic…"
        } catch { lastError = "Launch failed: \(error.localizedDescription)" }
    }

    /// The env var a user pastes into an Xcode scheme to capture Xcode-launched runs.
    var xcodeEnvHint: String {
        let dylib = dylibPath ?? "<path-to>/libSnoopyHook.dylib"
        return "DYLD_INSERT_LIBRARIES=\(dylib)\nSNOOPY_SOCKET=\(socketPath)"
    }

    func copyXcodeHint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(xcodeEnvHint, forType: .string)
    }

    func exportHAR() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "snoopy-session.har"
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try HARExport.data(from: store.exchanges).write(to: url) }
        catch { lastError = "Export failed: \(error.localizedDescription)" }
    }
}
