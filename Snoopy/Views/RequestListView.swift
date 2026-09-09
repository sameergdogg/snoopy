import SwiftUI
import SnoopyCore

struct RequestListView: View {
    let exchanges: [Exchange]
    @Binding var selection: Exchange.ID?

    var body: some View {
        Table(exchanges, selection: $selection) {
            TableColumn("") { ex in StatusDot(exchange: ex) }.width(18)
            TableColumn("Method") { ex in
                Text(ex.method).font(.system(.body, design: .monospaced))
                    .foregroundStyle(methodColor(ex.method))
            }.width(min: 52, ideal: 60, max: 80)
            TableColumn("Status") { ex in
                Text(ex.status.map(String.init) ?? (ex.state == .failed ? "err" : "…"))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(statusColor(ex))
            }.width(min: 48, ideal: 56, max: 70)
            TableColumn("Host") { ex in Text(ex.host).lineLimit(1) }.width(min: 100, ideal: 160, max: 260)
            TableColumn("Path") { ex in Text(ex.path).lineLimit(1).foregroundStyle(.secondary) }
            TableColumn("Size") { ex in
                Text(byteString(ex.responseBodySize ?? ex.responseBody?.count))
                    .foregroundStyle(.secondary).font(.callout)
            }.width(min: 56, ideal: 64, max: 90)
            TableColumn("Time") { ex in
                Text(ex.duration.map { String(format: "%.0f ms", $0 * 1000) } ?? "—")
                    .foregroundStyle(.secondary).font(.callout)
            }.width(min: 56, ideal: 68, max: 100)
        }
        .tableStyle(.inset)
        .monospacedDigit()
    }

    func methodColor(_ m: String) -> Color {
        switch m.uppercased() {
        case "GET": return .blue
        case "POST": return .green
        case "PUT", "PATCH": return .orange
        case "DELETE": return .red
        default: return .primary
        }
    }
    func statusColor(_ ex: Exchange) -> Color {
        if ex.state == .failed { return .red }
        guard let s = ex.status else { return .secondary }
        switch s {
        case 200..<300: return .green
        case 300..<400: return .teal
        case 400..<500: return .orange
        case 500...: return .red
        default: return .secondary
        }
    }
}

struct StatusDot: View {
    let exchange: Exchange
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
    var color: Color {
        switch exchange.state {
        case .pending: return .yellow
        case .responded: return .blue
        case .complete: return (exchange.status ?? 0) >= 400 ? .orange : .green
        case .failed: return .red
        }
    }
}

func byteString(_ n: Int?) -> String {
    guard let n, n > 0 else { return "—" }
    if n < 1024 { return "\(n) B" }
    if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
    return String(format: "%.1f MB", Double(n) / (1024 * 1024))
}
