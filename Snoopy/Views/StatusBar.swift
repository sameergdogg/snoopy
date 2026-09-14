import SwiftUI
import SnoopyCore

/// A real status bar along the bottom of the window.
///
/// The capture's status line used to be two lines of `.caption2` wedged under the sidebar's
/// buttons, and the list of attached processes — which the store had all along — was not
/// rendered anywhere at all, so there was no way to tell whether the hook was connected.
struct StatusBar: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var store: CaptureStore

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(store.statusLine)
                .lineLimit(1)
                .truncationMode(.middle)

            if !store.attached.isEmpty {
                Divider().frame(height: 12)
                ForEach(store.attached) { p in
                    HStack(spacing: 3) {
                        Image(systemName: "app.connected.to.app.below.fill").font(.caption2)
                        Text("\(p.name) · \(p.pid)").monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                    .help(p.bundleId)
                }
            }

            Spacer()

            if store.withheldCount > 0 {
                Button {
                    store.showAllRows = true
                } label: {
                    Text("\(store.withheldCount.formatted()) older rows hidden while recording — show all")
                }
                .buttonStyle(.link)
            }
            if store.droppedCount > 0 {
                Text("\(store.droppedCount.formatted()) dropped").foregroundStyle(.tertiary)
            }
            Text(byteString(store.retainedBytes) + " held")
                .monospacedDigit().foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var dotColor: Color {
        switch store.recordingState {
        case .recording: return .red
        case .waiting:   return .orange
        case .paused:    return .secondary
        }
    }
}

/// A dismissible banner for non-fatal problems.
///
/// These were modal alerts, which meant "pick a simulator and an app first" stopped the
/// world and had to be acknowledged before anything else could happen.
struct NoticeBanner: View {
    let notice: Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(notice.text).font(.callout).lineLimit(2)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var symbol: String {
        switch notice.level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
    private var tint: Color {
        switch notice.level {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}
