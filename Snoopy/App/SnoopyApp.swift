import SwiftUI
import AppKit
import SnoopyCore

@main
struct SnoopyApp: App {
    @StateObject private var controller = AppController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(controller)
                .environmentObject(controller.store)
                .frame(minWidth: 1000, minHeight: 620)
                .onAppear { delegate.controller = controller }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Session…") { controller.openSession() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Save Session…") { controller.saveSession() }
                    .keyboardShortcut("s")
                Button("Export HAR…") { controller.exportHAR() }
                    .keyboardShortcut("e")
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
