import SwiftUI
import SnoopyCore

struct RootView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var store: CaptureStore
    @State private var selection: Exchange.ID?
    @State private var filterText = ""

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 340)
        } detail: {
            VSplit(selection: $selection, filterText: $filterText)
        }
        .toolbar { ToolbarView(filterText: $filterText) }
        .alert("Snoopy", isPresented: Binding(get: { controller.lastError != nil },
                                              set: { if !$0 { controller.lastError = nil } })) {
            Button("OK", role: .cancel) { controller.lastError = nil }
        } message: { Text(controller.lastError ?? "") }
    }
}

/// Vertical split: request list on top, detail below.
private struct VSplit: View {
    @Binding var selection: Exchange.ID?
    @Binding var filterText: String
    @EnvironmentObject var store: CaptureStore

    var filtered: [Exchange] {
        let base = store.exchanges
        guard !filterText.isEmpty else { return base }
        let q = filterText.lowercased()
        return base.filter { $0.urlString.lowercased().contains(q) || $0.method.lowercased().contains(q)
            || String($0.status ?? 0).contains(q) || $0.host.lowercased().contains(q) }
    }

    var body: some View {
        VSplitView {
            RequestListView(exchanges: filtered, selection: $selection)
                .frame(minHeight: 180)
            Group {
                if let id = selection, let ex = store.exchanges.first(where: { $0.id == id }) {
                    DetailView(exchange: ex)
                } else {
                    ContentUnavailablePlaceholder()
                }
            }
            .frame(minHeight: 200)
        }
    }
}

private struct ContentUnavailablePlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "dog.fill").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("Select a request").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
