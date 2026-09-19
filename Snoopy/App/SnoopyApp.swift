import SwiftUI
import AppKit
import SnoopyCore

@main
struct SnoopyApp: App {
    @StateObject private var controller = AppController()
    @StateObject private var updates = UpdateController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(controller)
                .environmentObject(controller.store)
                .environmentObject(updates)
                .frame(minWidth: 1000, minHeight: 620)
                .onAppear {
                    delegate.controller = controller
                    updates.checkInBackgroundIfDue()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updates.check(userInitiated: true) }
                }
                .disabled(updates.state == .checking)
                Toggle("Check Automatically", isOn: Binding(
                    get: { updates.automaticChecks },
                    set: { updates.automaticChecks = $0 }))
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Session…") { controller.openSession() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Save Session…") { controller.saveSession() }
                    .keyboardShortcut("s")
                Button("Export HAR…") { controller.exportHAR() }
                    .keyboardShortcut("e")
                Button("Export for Agent…") { controller.exportForAgent() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Toggle("Redact Credentials in Exports", isOn: Binding(
                    get: { controller.redactExports },
                    set: { controller.redactExports = $0 }))
            }
            CommandMenu("Capture") {
                Button(controller.store.isRecording ? "Pause Recording" : "Start Recording") {
                    controller.store.toggleRecording()
                }
                .keyboardShortcut("r")
                Button("Launch with Snoopy") { Task { await controller.launchSelected() } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(controller.selectedApp == nil)
                Divider()
                Button("Clear Session") { controller.store.clear() }
                    .keyboardShortcut("k")
                Button("Find in Capture") {
                    NotificationCenter.default.post(name: .snoopyFocusFilter, object: nil)
                }
                .keyboardShortcut("f")
                Toggle("Search Headers and Bodies", isOn: Binding(
                    get: { controller.store.deepSearch },
                    set: { controller.store.deepSearch = $0 }))
                Toggle("Show All Rows While Recording", isOn: Binding(
                    get: { controller.store.showAllRows },
                    set: { controller.store.showAllRows = $0 }))
            }
        }
    }
}

/// `deinit` on a `@StateObject` the app holds for its whole lifetime is not a reliable
/// place to release OS resources, so termination is handled explicitly: without this the
/// listening socket and its /tmp entry outlived every run.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var controller: AppController?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { controller?.shutdown() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
