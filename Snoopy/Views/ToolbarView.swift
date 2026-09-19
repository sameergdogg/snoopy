import SwiftUI
import SnoopyCore

struct ToolbarView: ToolbarContent {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var store: CaptureStore
    @FocusState.Binding var filterFocused: Bool

    var body: some ToolbarContent {
        // The record control comes first and is the visually loudest thing in the toolbar:
        // the app previously had no way to express "start", only a Pause toggle, so there
        // was nothing to press and nothing that said whether capture was on.
        ToolbarItem(placement: .navigation) {
            RecordButton()
        }
        ToolbarItemGroup(placement: .principal) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter by host, path, method, status", text: $store.filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 240)
                    .focused($filterFocused)
                Toggle(isOn: $store.deepSearch) {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Also search headers and text bodies (uses more memory)")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.clear() } label: { Label("Clear", systemImage: "trash") }
                .disabled(store.totalCount == 0)
            Menu {
                Button("Save Session…") { controller.saveSession() }
                Button("Open Session…") { controller.openSession() }
                Divider()
                Button("Export HAR…") { controller.exportHAR() }
                Divider()
                Button("Export for Agent…") { controller.exportForAgent() }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(store.totalCount == 0 && store.exchanges.isEmpty)
            Text(countLabel).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    /// Shows "matching / total" whenever a filter or time range hides rows.
    private var countLabel: String {
        store.matchCount == store.totalCount
            ? "\(store.totalCount)"
            : "\(store.matchCount)/\(store.totalCount)"
    }
}

/// One control that both reports the capture state and changes it.
///
/// Deliberately not animated. A `repeatForever` pulse on the waiting state looked right and
/// cost a continuous toolbar redraw for as long as the app sat idle — measurably, ~9% of a
/// core doing nothing. Colour alone distinguishes the three states.
struct RecordButton: View {
    @EnvironmentObject var store: CaptureStore

    var body: some View {
        Button { store.toggleRecording() } label: {
            HStack(spacing: 6) {
                Image(systemName: store.recordingState.symbol)
                    .foregroundStyle(tint)
                Text(store.recordingState.label)
                    .font(.callout)
            }
            .padding(.horizontal, 4)
        }
        .help(store.isRecording ? "Pause capture (⌘R)" : "Resume capture (⌘R)")
    }

    private var tint: Color {
        switch store.recordingState {
        case .recording: return .red
        case .waiting:   return .orange
        case .paused:    return .secondary
        }
    }
}
