import SwiftUI
import SnoopyCore

/// The update affordance: a strip above the capture when something newer exists, and
/// nothing at all the rest of the time.
struct UpdateBanner: View {
    @EnvironmentObject var updates: UpdateController
    @State private var showNotes = false

    var body: some View {
        switch updates.state {
        case .idle, .checking:
            EmptyView()

        case .available(let release):
            strip(icon: "arrow.down.circle.fill", tint: .accentColor) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Snoopy \(release.version.description) is available")
                        .font(.callout).bold()
                    if let size = release.downloadSize {
                        Text(byteString(size)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } actions: {
                if !release.notes.isEmpty {
                    Button("What's new") { showNotes = true }.buttonStyle(.link)
                }
                Button("Download") { updates.download(release) }.buttonStyle(.borderedProminent)
                Button("Skip") { updates.skip(release) }.buttonStyle(.borderless)
                Button { updates.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .sheet(isPresented: $showNotes) { ReleaseNotesSheet(release: release) }

        case .downloading(let progress):
            strip(icon: "arrow.down.circle", tint: .accentColor) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Downloading update…").font(.callout)
                    ProgressView(value: progress).progressViewStyle(.linear).frame(width: 200)
                }
            } actions: {
                Button("Cancel") { updates.dismiss() }.buttonStyle(.borderless)
            }

        case .downloaded(let url):
            strip(icon: "checkmark.circle.fill", tint: .green) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update downloaded").font(.callout).bold()
                    // Says the quiet part out loud rather than implying it installed itself.
                    Text("Open it and drag Snoopy to Applications, replacing this copy.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } actions: {
                Button("Open") { updates.openInstaller(url) }.buttonStyle(.borderedProminent)
                Button("Show in Finder") { updates.reveal(url) }.buttonStyle(.borderless)
                Button { updates.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }

        case .upToDate(let version):
            strip(icon: "checkmark.circle", tint: .secondary) {
                Text("Snoopy \(version.description) is the latest version.").font(.callout)
            } actions: {
                Button { updates.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }

        case .failed(let message):
            strip(icon: "exclamationmark.triangle.fill", tint: .orange) {
                Text(message).font(.callout).lineLimit(2)
            } actions: {
                Button("Retry") { Task { await updates.check(userInitiated: true) } }.buttonStyle(.borderless)
                Button { updates.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
    }

    private func strip<Content: View, Actions: View>(
        icon: String, tint: Color,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            content()
            Spacer()
            actions()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(tint.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct ReleaseNotesSheet: View {
    let release: UpdateChecker.Release
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(release.name).font(.headline)
                    if let date = release.publishedAt {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Link("View on GitHub", destination: release.pageURL).font(.caption)
            }
            .padding(14)
            Divider()
            ScrollView {
                // GitHub release bodies are Markdown; rendering it beats showing the source.
                Text(attributedNotes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(width: 560, height: 460)
    }

    private var attributedNotes: AttributedString {
        (try? AttributedString(
            markdown: release.notes,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(release.notes)
    }
}
