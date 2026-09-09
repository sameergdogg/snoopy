import SwiftUI

struct ToolbarView: ToolbarContent {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var store: CaptureStore
    @Binding var filterText: String

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            TextField("Filter by host, path, method, status", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.isPaused.toggle() } label: {
                Label(store.isPaused ? "Resume" : "Pause",
                      systemImage: store.isPaused ? "play.fill" : "pause.fill")
            }
            Button { store.clear() } label: { Label("Clear", systemImage: "trash") }
            Button { controller.exportHAR() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(store.exchanges.isEmpty)
            Text("\(store.exchanges.count)").monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
