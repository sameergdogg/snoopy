import SwiftUI
import SnoopyCore

/// Interactive JSON viewer: collapsible objects/arrays, live search with highlight,
/// auto-expand to matches, and an optional filter that hides non-matching subtrees.
struct JSONTreeView: View {
    let root: JSONNode
    var initialQuery: String = ""

    @State private var expanded: Set<String> = []
    @State private var collapsedByUser: Set<String> = []
    @State private var query: String = ""
    @State private var filterToMatches = false
    @State private var didInit = false

    private var search: (matches: Set<String>, ancestors: Set<String>) {
        query.isEmpty ? ([], []) : root.search(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            Divider()
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleRows(), id: \.node.id) { item in
                        JSONRow(node: item.node, depth: item.depth,
                                isExpanded: isExpanded(item.node),
                                query: query,
                                isMatch: search.matches.contains(item.node.id),
                                toggle: { toggle(item.node) })
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if !didInit { if !initialQuery.isEmpty { query = initialQuery; autoExpandForSearch() }; expandTopLevels(); didInit = true } }
        .onChange(of: query) { _, _ in autoExpandForSearch() }
    }

    private var controls: some View {
        let s = search
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Search keys and values", text: $query)
                .textFieldStyle(.plain).font(.system(.caption, design: .monospaced))
            if !query.isEmpty {
                Text("\(s.matches.count)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                Toggle("Filter", isOn: $filterToMatches).toggleStyle(.button).controlSize(.mini)
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Expand all") { expandAll(root); collapsedByUser.removeAll() }.buttonStyle(.borderless).font(.caption2)
            Button("Collapse all") { expanded.removeAll(); collapsedByUser.removeAll() }.buttonStyle(.borderless).font(.caption2)
        }
        .padding(.horizontal, 4)
    }

    // MARK: rows (flattened to avoid self-recursive opaque View types)

    private struct Row { let node: JSONNode; let depth: Int }

    private func visibleRows() -> [Row] {
        var out: [Row] = []
        let s = search
        func walk(_ node: JSONNode, _ depth: Int) {
            let shown = !filterToMatches || query.isEmpty
                || s.matches.contains(node.id) || s.ancestors.contains(node.id)
            guard shown else { return }
            out.append(Row(node: node, depth: depth))
            if node.isContainer, isExpanded(node) {
                for child in node.children ?? [] { walk(child, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }

    // MARK: expansion state

    private func isExpanded(_ node: JSONNode) -> Bool {
        guard node.isContainer else { return false }
        if !query.isEmpty, search.ancestors.contains(node.id), !collapsedByUser.contains(node.id) { return true }
        return expanded.contains(node.id)
    }
    private func toggle(_ node: JSONNode) {
        guard node.isContainer else { return }
        if isExpanded(node) { expanded.remove(node.id); collapsedByUser.insert(node.id) }
        else { expanded.insert(node.id); collapsedByUser.remove(node.id) }
    }
    private func expandTopLevels() {
        expanded.insert(root.id)
        for c in root.children ?? [] where c.isContainer { expanded.insert(c.id) }
    }
    private func expandAll(_ node: JSONNode) {
        if node.isContainer { expanded.insert(node.id) }
        for c in node.children ?? [] { expandAll(c) }
    }
    private func autoExpandForSearch() {
        guard !query.isEmpty else { return }
        expanded.formUnion(search.ancestors)
    }
}

private struct JSONRow: View {
    let node: JSONNode
    let depth: Int
    let isExpanded: Bool
    let query: String
    let isMatch: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            // disclosure triangle for containers, else spacer
            if node.isContainer {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggle)
            } else {
                Spacer().frame(width: 12)
            }

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if let label = node.label {
                    highlighted(label, isKey: node.key != nil)
                    Text(node.key != nil ? ": " : "  ").foregroundStyle(.secondary)
                }
                if node.isContainer {
                    if isExpanded {
                        Text(node.kind == .object ? "{" : "[").foregroundStyle(.secondary)
                    } else {
                        Text(node.collapsedSummary)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 0)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                            .onTapGesture(perform: toggle)
                    }
                } else {
                    highlighted(node.scalarText, isKey: false)
                        .foregroundStyle(color(for: node.kind))
                }
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 1)
        .background(isMatch && !query.isEmpty ? Color.yellow.opacity(0.18) : .clear)
    }

    @ViewBuilder
    private func highlighted(_ text: String, isKey: Bool) -> some View {
        let base: Color = isKey ? .primary : .primary
        if query.isEmpty || !text.lowercased().contains(query.lowercased()) {
            Text(text).foregroundStyle(isKey ? Color.accentColor : base)
        } else {
            Text(attributed(text, query: query)).foregroundStyle(isKey ? Color.accentColor : base)
        }
    }

    private func attributed(_ text: String, query: String) -> AttributedString {
        var str = AttributedString(text)
        let lower = text.lowercased(); let lq = query.lowercased()
        var searchStart = lower.startIndex
        while let r = lower.range(of: lq, range: searchStart..<lower.endIndex) {
            // map String range to AttributedString range
            let lo = text.distance(from: text.startIndex, to: r.lowerBound)
            let hi = text.distance(from: text.startIndex, to: r.upperBound)
            if let aLo = str.index(str.startIndex, offsetByCharacters: lo, limitedBy: str.endIndex),
               let aHi = str.index(str.startIndex, offsetByCharacters: hi, limitedBy: str.endIndex) {
                str[aLo..<aHi].backgroundColor = .yellow.opacity(0.6)
                str[aLo..<aHi].foregroundColor = .black
            }
            searchStart = r.upperBound
        }
        return str
    }

    private func color(for kind: JSONNode.Kind) -> Color {
        switch kind {
        case .string: return .green
        case .number: return .orange
        case .bool:   return .purple
        case .null:   return .secondary
        default:      return .primary
        }
    }
}

private extension AttributedString {
    func index(_ i: AttributedString.Index, offsetByCharacters n: Int, limitedBy limit: AttributedString.Index) -> AttributedString.Index? {
        characters.index(i, offsetBy: n, limitedBy: limit)
    }
}
