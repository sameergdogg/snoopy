import SwiftUI
import SnoopyCore

struct DetailView: View {
    let exchange: Exchange
    @State private var tab = Tab.request

    enum Tab: String, CaseIterable { case request = "Request", response = "Response", timing = "Timing" }

    var body: some View {
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
            ScrollView {
                switch tab {
                case .request: RequestPane(exchange: exchange)
                case .response: ResponsePane(exchange: exchange)
                case .timing: TimingPane(exchange: exchange)
                }
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
        var parts = ["curl", "-X", exchange.method, "'\(exchange.urlString)'"]
        for (k, v) in exchange.requestHeaders { parts.append("-H '\(k): \(v)'") }
        if let b = exchange.requestBody, let s = String(data: b, encoding: .utf8) {
            parts.append("--data '\(s)'")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: " "), forType: .string)
    }
}

private struct RequestPane: View {
    let exchange: Exchange
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeadersSection(title: "Request Headers", headers: exchange.requestHeaders)
            if let omitted = exchange.requestBodyOmitted {
                LabeledBox(title: "Body") { Text("Not captured (\(omitted))").foregroundStyle(.secondary) }
            } else {
                BodySection(title: "Request Body", data: exchange.requestBody,
                            headers: exchange.requestHeaders, mimeType: nil,
                            truncated: exchange.requestBodyTruncated, fullSize: exchange.requestBodySize)
            }
        }.padding(12)
    }
}

private struct ResponsePane: View {
    let exchange: Exchange
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeadersSection(title: "Response Headers", headers: exchange.responseHeaders)
            BodySection(title: "Response Body", data: exchange.responseBody,
                        headers: exchange.responseHeaders, mimeType: exchange.mimeType,
                        truncated: exchange.responseBodyTruncated, fullSize: exchange.responseBodySize)
        }.padding(12)
    }
}

private struct HeadersSection: View {
    let title: String
    let headers: [String: String]
    var body: some View {
        LabeledBox(title: "\(title) (\(headers.count))") {
            if headers.isEmpty { Text("None").foregroundStyle(.secondary) }
            else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                        HStack(alignment: .top, spacing: 6) {
                            Text(k).foregroundStyle(.secondary).frame(width: 180, alignment: .leading)
                            Text(v).textSelection(.enabled)
                        }.font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
    }
}

private struct BodySection: View {
    let title: String
    let data: Data?
    let headers: [String: String]
    let mimeType: String?
    let truncated: Bool
    let fullSize: Int?
    @State private var mode = 0   // 0 pretty, 1 raw, 2 hex

    var decoded: Data { data.map { BodyFormatter.decoded($0, headers: headers) } ?? Data() }
    var kind: BodyFormatter.Kind { BodyFormatter.kind(mimeType: mimeType, headers: headers, data: decoded) }

    var body: some View {
        LabeledBox(title: bodyTitle) {
            if data == nil || data!.isEmpty {
                Text("Empty").foregroundStyle(.secondary)
            } else {
                Picker("", selection: $mode) {
                    Text("Pretty").tag(0); Text("Raw").tag(1); Text("Hex").tag(2)
                }.pickerStyle(.segmented).frame(width: 220).labelsHidden().padding(.bottom, 4)

                if kind == .image, mode == 0, let img = NSImage(data: decoded) {
                    Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 320)
                } else if kind == .json, mode == 0, let node = JSONNode.parse(decoded) {
                    JSONTreeView(root: node).frame(minHeight: 120, maxHeight: 460)
                } else {
                    Text(bodyText).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if truncated { Text("Truncated for display").font(.caption2).foregroundStyle(.orange) }
            }
        }
    }
    var bodyTitle: String {
        var t = title
        if let n = fullSize ?? data?.count { t += " (\(byteString(n)))" }
        return t
    }
    var bodyText: String {
        switch mode {
        case 2: return BodyFormatter.hexDump(decoded)
        case 1: return BodyFormatter.text(decoded)
        default:
            if kind == .json, let p = BodyFormatter.prettyJSON(decoded) { return p }
            return BodyFormatter.text(decoded)
        }
    }
}

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
                    ("Started", exchange.startedAt.formatted(date: .omitted, time: .standard)),
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
