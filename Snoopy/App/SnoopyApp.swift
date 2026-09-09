import SwiftUI
import SnoopyCore

@main
struct SnoopyApp: App {
    @StateObject private var controller = AppController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(controller)
                .environmentObject(controller.store)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Clear Session") { controller.store.clear() }.keyboardShortcut("k")
                Button("Export HAR…") { controller.exportHAR() }.keyboardShortcut("e")
            }
        }
    }
}
