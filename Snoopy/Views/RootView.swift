import SwiftUI
import SnoopyCore

struct RootView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var store: CaptureStore
    @State private var selection: Exchange.ID?
    @FocusState private var filterFocused: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if let notice = controller.notice {
                    NoticeBanner(notice: notice) { controller.notice = nil }
                }
                VSplit(selection: $selection)
                Divider()
                StatusBar()
            }
            .animation(.easeInOut(duration: 0.15), value: controller.notice)
        }
        .toolbar { ToolbarView(filterFocused: $filterFocused) }
        .onReceive(NotificationCenter.default.publisher(for: .snoopyFocusFilter)) { _ in
            filterFocused = true
        }
        // Non-fatal problems are banners now; an alert is reserved for nothing at all,
        // since there is no condition here the user cannot keep working through.
        .task(id: controller.notice?.id) {
            guard let n = controller.notice, n.level == .info else { return }
            try? await Task.sleep(for: .seconds(4))
            if controller.notice?.id == n.id { controller.notice = nil }
        }
    }
}

extension Notification.Name {
    static let snoopyFocusFilter = Notification.Name("dev.snoopy.focusFilter")
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
                // The list gets a modest ideal height and the detail pane takes the rest.
                // An even split spent most of the window on empty table rows while the
                // pane you actually read — headers, body, JSON tree — was clipped.
                RequestListView(exchanges: store.visible, selection: $selection)
                    .frame(minHeight: 120, idealHeight: 200)
                Group {
                    // O(1) via the store's id index; this used to be a linear scan of the
                    // whole history on every render.
                    if let id = selection, let ex = store.exchange(id: id) {
                        DetailView(exchange: ex)
                    } else {
                        ContentUnavailablePlaceholder(hasRows: !store.visible.isEmpty)
                    }
                }
                .frame(minHeight: 260, maxHeight: .infinity)
            }
        }
    }
}

private struct ContentUnavailablePlaceholder: View {
    let hasRows: Bool
    @EnvironmentObject var store: CaptureStore

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "dog.fill").font(.system(size: 40)).foregroundStyle(.tertiary)
            if hasRows {
                Text("Select a request").foregroundStyle(.secondary)
            } else {
                // A first-run path that actually says what to do, instead of an empty pane.
                Text(store.isRecording ? "Recording — nothing captured yet" : "Capture is paused")
                    .foregroundStyle(.secondary)
                Text(store.isRecording
                     ? "Pick a simulator and an app on the left, then Launch with Snoopy."
                     : "Press Record in the toolbar to start capturing.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
