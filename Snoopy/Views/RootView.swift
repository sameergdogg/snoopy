import SwiftUI
import SnoopyCore

struct RootView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var store: CaptureStore
    @State private var selection: Exchange.ID?

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 340)
        } detail: {
            VSplit(selection: $selection)
        }
        .toolbar { ToolbarView() }
        .alert("Snoopy", isPresented: Binding(get: { controller.lastError != nil },
                                              set: { if !$0 { controller.lastError = nil } })) {
            Button("OK", role: .cancel) { controller.lastError = nil }
        } message: { Text(controller.lastError ?? "") }
    }
}

/// Timeline on top, then a vertical split: request list above, detail below.
private struct VSplit: View {
    @Binding var selection: Exchange.ID?
    @EnvironmentObject var store: CaptureStore

    var body: some View {
        VStack(spacing: 0) {
            TimelineStrip()
            Divider()
            VSplitView {
                RequestListView(exchanges: store.visible, selection: $selection)
                    .frame(minHeight: 180)
                Group {
                    // O(1) via the store's id index; this used to be a linear scan of the
                    // whole history on every render.
                    if let id = selection, let ex = store.exchange(id: id) {
                        DetailView(exchange: ex)
                    } else {
                        ContentUnavailablePlaceholder()
                    }
                }
                .frame(minHeight: 200)
            }
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
