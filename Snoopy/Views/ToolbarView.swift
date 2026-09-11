import SwiftUI

struct ToolbarView: ToolbarContent {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var store: CaptureStore

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            TextField("Filter by host, path, method, status",
                      text: Binding(get: { store.filterText }, set: { store.filterText = $0 }))
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
                .disabled(store.totalCount == 0)
            Text(countLabel).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    /// Shows "matching / total" whenever a filter or time range hides rows. The display cap
    /// on the table itself is reported in the timeline header, where there is room to explain it.
    private var countLabel: String {
        store.matchCount == store.totalCount
            ? "\(store.totalCount)"
            : "\(store.matchCount)/\(store.totalCount)"
    }
}
