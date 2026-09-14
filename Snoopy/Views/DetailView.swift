import SwiftUI
import UniformTypeIdentifiers
import SnoopyCore

struct DetailView: View {
    let exchange: Exchange
    @State private var tab = Tab.request

    enum Tab: String, CaseIterable { case request = "Request", response = "Response", timing = "Timing" }

    var body: some View {
        // No outer `ScrollView` here any more. Wrapping the whole pane in one proposed an
        // unbounded height to everything inside it, which is what made a large body lay out
        // in full instead of lazily, and it put the JSON tree's own scroll view inside
        // another one — two scrollers fighting over the same wheel events.
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch tab {
            case .request: RequestPane(exchange: exchange)
            case .response: ResponsePane(exchange: exchange)
            case .timing: ScrollView { TimingPane(exchange: exchange) }
            }
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(exchange.method).font(.system(.body, design: .monospaced)).bold()
                if let s = exchange.status {
                    Text("\(s)").font(.system(.body, design: .monospaced))
                        .foregroundStyle(s >= 400 ? .orange : .green)
                }
                Text(exchange.startedAtText).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let d = exchange.duration {
                    Text(String(format: "%.0f ms", d * 1000)).foregroundStyle(.secondary)
                }
                if let p = exchange.metrics?.networkProtocol {
                    Text(p).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Button { copyCurl() } label: { Label("Copy cURL", systemImage: "terminal") }
                    .buttonStyle(.borderless).font(.caption)
            }
            Text(exchange.urlString).font(.callout).textSelection(.enabled).lineLimit(3)
            if let err = exchange.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func copyCurl() {
        var parts = ["curl", "-X", Shell.quote(exchange.method), Shell.quote(exchange.urlString)]
        for f in exchange.requestHeaders {
            parts.append("-H " + Shell.quote("\(f.name): \(f.value)"))
        }
        if let b = exchange.requestBody {
            // A body that is not valid UTF-8 cannot go inside a quoted string at all;
            // the previous version pasted the replacement characters in and produced a
            // command that sent different bytes than the app did.
            if let s = String(data: b, encoding: .utf8) {
                parts.append("--data-raw " + Shell.quote(s))
            } else {
                parts.append("--data-binary @/path/to/body.bin  # body is not UTF-8; use Save Body…")
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: " "), forType: .string)
    }
}

enum Shell {
    /// POSIX single-quoting. The old `'\(value)'` interpolation broke on any value
    /// containing a quote — common in cookies, JSON bodies and signed URLs — and produced
    /// a command that either failed to parse or, worse, ran something unintended.
    static func quote(_ s: String) -> String {
        guard !s.isEmpty else { return "''" }
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "._-/:=@".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Panes

private struct RequestPane: View {
    let exchange: Exchange
    var body: some View {
        VStack(spacing: 0) {
            HeadersSection(title: "Request Headers", headers: exchange.requestHeaders)
            Divider()
            if let omitted = exchange.requestBodyOmitted {
                VStack {
                    Text("Body not captured (\(omitted))").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BodySection(exchange: exchange, slot: .request)
            }
        }
    }
}

private struct ResponsePane: View {
    let exchange: Exchange
    var body: some View {
        VStack(spacing: 0) {
            HeadersSection(title: "Response Headers", headers: exchange.responseHeaders)
            Divider()
            BodySection(exchange: exchange, slot: .response)
        }
    }
}

/// Headers in wire order, with repeated fields shown as the separate fields they are.
private struct HeadersSection: View {
    let title: String
    let headers: Headers
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if headers.isEmpty {
                Text("None").foregroundStyle(.secondary).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        // Index-keyed: two `Set-Cookie` fields are two rows, and a name is
                        // no longer a unique identifier now that duplicates survive.
                        ForEach(Array(headers.enumerated()), id: \.offset) { _, f in
                            HStack(alignment: .top, spacing: 6) {
                                Text(f.name).foregroundStyle(.secondary)
                                    .frame(width: 180, alignment: .leading)
                                Text(f.value).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(.caption, design: .monospaced))
                        }
                    }.padding(.vertical, 4)
                }
                .frame(maxHeight: 160)
            }
        } label: {
            HStack(spacing: 6) {
                Text("\(title) (\(headers.count))").font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n"), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).font(.caption2).foregroundStyle(.secondary)
                    .help("Copy headers")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Body rendering

private struct BodySection: View {
    enum Slot { case request, response }

    let exchange: Exchange
    let slot: Slot

    @State private var mode = BodyPreview.Mode.pretty
    @State private var preview: BodyPreview?
    @State private var preparing = false
    @State private var image: NSImage?

    private var data: Data? { slot == .request ? exchange.requestBody : exchange.responseBody }
    private var headers: Headers { slot == .request ? exchange.requestHeaders : exchange.responseHeaders }
    private var mimeType: String? { slot == .request ? nil : exchange.mimeType }
    private var truncated: Bool { slot == .request ? exchange.requestBodyTruncated : exchange.responseBodyTruncated }
    private var fullSize: Int? { slot == .request ? exchange.requestBodySize : exchange.responseBodySize }
    private var bodyId: String { exchange.id + (slot == .request ? "#req" : "#resp") }

    private struct Key: Equatable { let id: String; let mode: BodyPreview.Mode }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: Key(id: bodyId, mode: mode)) { await prepare() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).bold().foregroundStyle(.secondary)
            Spacer()
            if hasBody {
                if let doc = textDocument {
                    Text("\(doc.lineCount.formatted()) lines")
                        .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                }
                Picker("", selection: $mode) {
                    ForEach(BodyPreview.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 190).labelsHidden().controlSize(.small)
                Button { copyBody() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).font(.caption).help("Copy body")
                    .disabled(preview == nil)
                // The escape hatch for a payload too big to read in a pane — previously the
                // only suggestion was to export the entire session as HAR.
                Button { saveBody() } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless).font(.caption).help("Save body…")
                    .disabled(preview == nil)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var hasBody: Bool { !(data?.isEmpty ?? true) }

    private var textDocument: TextDocument? {
        if case .text(let doc)? = preview?.content { return doc }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        if exchange.bodiesReaped, data == nil, (fullSize ?? 0) > 0 {
            placeholder("Body released to stay within the memory budget (\(byteString(fullSize)) captured).")
        } else if !hasBody {
            placeholder("Empty")
        } else if let p = preview {
            VStack(alignment: .leading, spacing: 0) {
                if let note = p.note {
                    Text(note).font(.caption2).foregroundStyle(.orange)
                        .padding(.horizontal, 12).padding(.top, 6)
                }
                if truncated {
                    Text("Truncated at capture — raise SNOOPY_MAX_RESPONSE_BODY to keep more.")
                        .font(.caption2).foregroundStyle(.orange)
                        .padding(.horizontal, 12).padding(.top, 6)
                }
                switch p.content {
                case .json(let root, let nodeCount):
                    JSONTreeView(root: root, treeId: bodyId, nodeCount: nodeCount)
                case .text(let doc):
                    TextDocumentView(document: doc, showsLineNumbers: mode != .hex)
                case .image:
                    if let image {
                        ScrollView { Image(nsImage: image).resizable().scaledToFit().padding(12) }
                    } else {
                        placeholder("Not a decodable image")
                    }
                case .empty:
                    placeholder("Empty")
                }
            }
        } else if preparing {
            VStack {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Decoding \(byteString(fullSize ?? data?.count))…")
                        .foregroundStyle(.secondary).font(.caption)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).font(.callout)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func prepare() async {
        guard let data, !data.isEmpty else { preview = nil; image = nil; return }
        preview = nil
        preparing = true
        let h = headers, m = mimeType, mo = mode
        let result = await Task.detached(priority: .userInitiated) {
            BodyPreview.make(data: data, headers: h, mimeType: m, mode: mo)
        }.value
        guard !Task.isCancelled else { return }
        preparing = false
        preview = result
        image = result.kind == .image ? NSImage(data: result.decoded) : nil
    }

    private var title: String {
        var t = slot == .request ? "Request Body" : "Response Body"
        if let n = fullSize ?? data?.count { t += " (\(byteString(n)))" }
        return t
    }

    private func copyBody() {
        guard let p = preview else { return }
        let text: String
        switch p.content {
        case .json(let root, _): text = root.jsonText()
        case .text(let doc): text = doc.chunks.map(\.text).joined(separator: "\n")
        case .image, .empty: text = ""
        }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveBody() {
        guard let p = preview else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = BodyFormatter.suggestedFilename(
            url: exchange.url, kind: p.kind, mimeType: mimeType)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The decoded (decompressed) bytes, not the display text — a saved body should be
        // byte-identical to what the app received.
        try? p.decoded.write(to: url)
    }
}

/// Renders a `TextDocument` chunk by chunk inside a `LazyVStack`, so only the chunks near
/// the viewport are ever laid out. This is the fix for large bodies: the cost of showing a
/// 200,000-line response is now the cost of showing one screenful of it.
private struct TextDocumentView: View {
    let document: TextDocument
    var showsLineNumbers = true

    var body: some View {
        // Vertical only, for the same reason as the JSON tree: a bidirectional scroll
        // view proposes an unbounded width and the chunks fail to lay out inside it.
        // Long lines wrap, which for a body viewer beats not rendering at all.
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(document.chunks) { chunk in
                    HStack(alignment: .top, spacing: 8) {
                        if showsLineNumbers {
                            Text(lineNumbers(for: chunk))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 52, alignment: .trailing)
                        }
                        Text(chunk.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
                if document.truncated {
                    Text("Display limited to \(byteString(document.byteCount)) — use Save Body for the rest.")
                        .font(.caption2).foregroundStyle(.orange).padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One `Text` of right-aligned numbers per chunk rather than one per line — the gutter
    /// should not multiply the view count it exists to annotate.
    private func lineNumbers(for chunk: TextDocument.Chunk) -> String {
        (0..<chunk.lineCount).map { String(chunk.firstLine + $0) }.joined(separator: "\n")
    }
}

// MARK: - Timing

private struct TimingPane: View {
    let exchange: Exchange
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let m = exchange.metrics {
                LabeledBox(title: "Connection") {
                    grid([
                        ("Protocol", m.networkProtocol ?? "—"),
                        ("Remote address", m.remoteAddress ?? "—"),
                        ("Reused connection", m.reused.map { $0 ? "yes" : "no" } ?? "—"),
                        ("Redirects", m.redirectCount.map(String.init) ?? "—"),
                    ])
                }
                LabeledBox(title: "Phases") { WaterfallView(timing: m) }
            } else {
                Text("No detailed metrics.\nTiming is available when the app uses a URLSession delegate.")
                    .foregroundStyle(.secondary).font(.callout)
            }
            LabeledBox(title: "Totals") {
                grid([
                    ("Started", exchange.startedAtText),
                    ("Duration", exchange.duration.map { String(format: "%.1f ms", $0 * 1000) } ?? "—"),
                ])
            }
        }.padding(12)
    }
    func grid(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.0) { k, v in
                HStack { Text(k).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                    Text(v).textSelection(.enabled) }.font(.system(.caption, design: .monospaced))
            }
        }
    }
}

private struct WaterfallView: View {
    let timing: Timing
    struct Phase: Identifiable { let id = UUID(); let name: String; let start: Date; let end: Date; let color: Color }

    var phases: [Phase] {
        var out: [Phase] = []
        func add(_ n: String, _ a: Date?, _ b: Date?, _ c: Color) { if let a, let b, b > a { out.append(.init(name: n, start: a, end: b, color: c)) } }
        add("DNS", timing.dnsStart, timing.dnsEnd, .purple)
        add("Connect", timing.connectStart, timing.connectEnd, .blue)
        add("TLS", timing.tlsStart, timing.tlsEnd, .teal)
        add("Request", timing.requestStart, timing.requestEnd, .green)
        add("Wait", timing.requestEnd, timing.responseStart, .orange)
        add("Response", timing.responseStart, timing.responseEnd, .pink)
        return out
    }
    var body: some View {
        let all = phases
        guard let first = all.map(\.start).min(), let last = all.map(\.end).max(), last > first else {
            return AnyView(Text("—").foregroundStyle(.secondary))
        }
        let total = last.timeIntervalSince(first)
        return AnyView(VStack(alignment: .leading, spacing: 4) {
            ForEach(all) { p in
                HStack(spacing: 6) {
                    Text(p.name).font(.caption2).frame(width: 64, alignment: .leading)
                    GeometryReader { geo in
                        let w = geo.size.width
                        let x = p.start.timeIntervalSince(first) / total * w
                        let len = max(2, p.end.timeIntervalSince(p.start) / total * w)
                        RoundedRectangle(cornerRadius: 2).fill(p.color)
                            .frame(width: len).offset(x: x)
                    }.frame(height: 12)
                    Text(String(format: "%.0f ms", p.end.timeIntervalSince(p.start) * 1000))
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                }
            }
        })
    }
}

struct LabeledBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).bold().foregroundStyle(.secondary)
            content.frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
