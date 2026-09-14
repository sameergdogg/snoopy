import SwiftUI
import SnoopyCore

/// Interactive JSON viewer: collapsible objects/arrays, live search with highlight,
/// auto-expand to matches, and an optional filter that hides non-matching subtrees.
///
/// Three things keep it responsive on the documents that used to defeat it:
///
/// - **Large containers are paged.** An array of 20,000 elements shows a page at a time with
///   a row to load more, so "expand" can never flatten a whole document into the row list.
///   The old viewer had no page concept, and its one defence was a 60,000-node parse budget
///   that simply refused to build a tree at all for ordinary API responses.
/// - **Search runs off the main actor, debounced.** It walked every node on every keystroke,
///   synchronously; on a big tree each character cost a full-document scan.
/// - **Ids are integers.** Expansion and match sets were `Set<String>` of path strings.
struct JSONTreeView: View {
    let root: JSONNode
    /// Identifies the document, so state resets when a different body is shown. Node ids are
    /// only unique within one parse, so they cannot serve this purpose themselves.
    let treeId: String
    var nodeCount: Int = 0
    var initialQuery: String = ""

    @State private var expanded: Set<Int> = []
    @State private var collapsedByUser: Set<Int> = []
    @State private var pageSize: [Int: Int] = [:]
    @State private var query: String = ""
    @State private var liveQuery: String = ""
    @State private var filterToMatches = false
    @State private var searching = false

    @State private var matches: Set<Int> = []
    @State private var ancestors: Set<Int> = []
    @State private var rows: [Row] = []
    @State private var loadedTreeId: String?

    /// Children shown per container before a "show more" row appears.
    private static let pageStep = 200

    enum Row: Identifiable {
        case node(JSONNode, depth: Int)
        /// A "… 4,800 more" affordance for the container with this id.
        case more(parent: Int, remaining: Int, depth: Int)

        var id: Int {
            switch self {
            case .node(let n, _): return n.id
            // Negative keys cannot collide with a node id, which is a non-negative pre-order index.
            case .more(let parent, _, _): return -(parent + 1)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            // Vertical only. A scroll view that scrolls both ways proposes an unbounded
            // width to its content, and `LazyVStack` + `Text` resolve that to something
            // the rows cannot lay out inside — the tree drew as a bare column of
            // disclosure triangles with every key and value invisible. Long values are
            // truncated per row instead, with the full text a right-click (Copy value) or
            // the Raw tab away, which is what a tree view wants anyway.
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        switch row {
                        case .node(let node, let depth):
                            JSONRow(node: node, depth: depth,
                                    isExpanded: isExpanded(node),
                                    query: query,
                                    isMatch: matches.contains(node.id),
                                    toggle: { toggle(node) },
                                    copyPath: { copyPath(of: node) },
                                    copyValue: { copyValue(of: node) })
                        case .more(let parent, let remaining, let depth):
                            MoreRow(remaining: remaining, depth: depth) {
                                pageSize[parent] = (pageSize[parent] ?? Self.pageStep) + Self.pageStep
                                rebuildRows()
                            } showAll: {
                                pageSize[parent] = Int.max
                                rebuildRows()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { resetIfNeeded() }
        .onChange(of: treeId) { _, _ in resetIfNeeded() }
        // Debounced: `liveQuery` follows the field, `query` follows it a beat later, and only
        // `query` triggers a search. Typing "user" used to run four whole-document scans.
        .task(id: liveQuery) {
            guard liveQuery != query else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            query = liveQuery
            await runSearch()
        }
        .onChange(of: filterToMatches) { _, _ in rebuildRows() }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Search keys and values", text: $liveQuery)
                .textFieldStyle(.plain).font(.system(.caption, design: .monospaced))
            if searching { ProgressView().controlSize(.small).scaleEffect(0.6) }
            if !query.isEmpty {
                Text("\(matches.count)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                Toggle("Filter", isOn: $filterToMatches).toggleStyle(.button).controlSize(.mini)
                Button { liveQuery = ""; query = ""; Task { await runSearch() } } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Spacer()
            if nodeCount > 0 {
                Text("\(nodeCount.formatted()) values")
                    .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            }
            Button("Expand all") { expandAll() }.buttonStyle(.borderless).font(.caption2)
            Button("Collapse all") {
                expanded.removeAll(); collapsedByUser.removeAll(); pageSize.removeAll()
                expanded.insert(root.id)
                rebuildRows()
            }.buttonStyle(.borderless).font(.caption2)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: Derived state

    private func resetIfNeeded() {
        guard loadedTreeId != treeId else { return }
        loadedTreeId = treeId
        expanded.removeAll(); collapsedByUser.removeAll(); pageSize.removeAll()
        matches.removeAll(); ancestors.removeAll()
        liveQuery = initialQuery
        query = initialQuery
        expandTopLevels()
        Task { await runSearch() }
    }

    private func runSearch() async {
        let q = query
        guard !q.isEmpty else {
            matches = []; ancestors = []; rebuildRows(); return
        }
        searching = true
        let tree = root
        let result = await Task.detached(priority: .userInitiated) { tree.search(q) }.value
        guard q == query else { return }   // a newer query already superseded this one
        searching = false
        matches = result.matches
        ancestors = result.ancestors
        expanded.formUnion(result.ancestors)   // auto-expand to matches
        rebuildRows()
    }

    /// Flattens the visible part of the tree once, instead of on every body evaluation.
    /// Children beyond a container's current page are represented by a single `.more` row,
    /// which bounds this at (visible containers × page size) rather than the document size.
    private func rebuildRows() {
        var out: [Row] = []
        let filtering = filterToMatches && !query.isEmpty

        func walk(_ node: JSONNode, _ depth: Int) {
            if filtering, !matches.contains(node.id), !ancestors.contains(node.id) { return }
            out.append(.node(node, depth: depth))
            guard node.isContainer, isExpanded(node), let kids = node.children else { return }
            // While filtering, the page limit would hide matches that sit past it, so the
            // page applies only to the unfiltered view.
            let limit = filtering ? Int.max : (pageSize[node.id] ?? Self.pageStep)
            for child in kids.prefix(limit) { walk(child, depth + 1) }
            if kids.count > limit {
                out.append(.more(parent: node.id, remaining: kids.count - limit, depth: depth + 1))
            }
        }
        walk(root, 0)
        rows = out
    }

    // MARK: expansion state

    private func isExpanded(_ node: JSONNode) -> Bool {
        guard node.isContainer else { return false }
        if !query.isEmpty, ancestors.contains(node.id), !collapsedByUser.contains(node.id) { return true }
        return expanded.contains(node.id)
    }

    private func toggle(_ node: JSONNode) {
        guard node.isContainer else { return }
        if isExpanded(node) { expanded.remove(node.id); collapsedByUser.insert(node.id) }
        else { expanded.insert(node.id); collapsedByUser.remove(node.id) }
        rebuildRows()
    }

    private func expandTopLevels() {
        expanded.insert(root.id)
        for c in root.children ?? [] where c.isContainer { expanded.insert(c.id) }
        rebuildRows()
    }

    /// Marks every container expanded. Paging still bounds the row list, so this is safe on
    /// a document where flattening everything would previously have produced 100k rows.
    private func expandAll() {
        var ids = Set<Int>()
        func walk(_ n: JSONNode) {
            guard n.isContainer else { return }
            ids.insert(n.id)
            for c in n.children ?? [] { walk(c) }
        }
        walk(root)
        expanded = ids
        collapsedByUser.removeAll()
        rebuildRows()
    }

    // MARK: Clipboard

    private func copyPath(of node: JSONNode) {
        guard let p = root.path(toID: node.id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(p, forType: .string)
    }

    private func copyValue(of node: JSONNode) {
        let text = node.isContainer ? node.jsonText() : node.rawScalar
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct MoreRow: View {
    let remaining: Int
    let depth: Int
    let showMore: () -> Void
    let showAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Show \(min(remaining, 200)) more") { showMore() }
            if remaining > 200 {
                Button("Show all \(remaining.formatted())") { showAll() }
            }
            Text("\(remaining.formatted()) hidden").foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .buttonStyle(.link)
        .padding(.leading, CGFloat(depth) * 14 + 12)
        .padding(.vertical, 2)
    }
}

private struct JSONRow: View {
    let node: JSONNode
    let depth: Int
    let isExpanded: Bool
    let query: String
    let isMatch: Bool
    let toggle: () -> Void
    let copyPath: () -> Void
    let copyValue: () -> Void

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
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 1)
        .background(isMatch && !query.isEmpty ? Color.yellow.opacity(0.18) : .clear)
        .contextMenu {
            Button("Copy value") { copyValue() }
            Button("Copy path") { copyPath() }
        }
    }

    @ViewBuilder
    private func highlighted(_ text: String, isKey: Bool) -> some View {
        // Case-insensitive range search avoids allocating a lowercased copy of the query
        // and of this row's text on every redraw.
        if query.isEmpty || text.range(of: query, options: .caseInsensitive) == nil {
            Text(text).foregroundStyle(isKey ? Color.accentColor : Color.primary)
        } else {
            Text(attributed(text, query: query)).foregroundStyle(isKey ? Color.accentColor : Color.primary)
        }
    }

    private func attributed(_ text: String, query: String) -> AttributedString {
        var str = AttributedString(text)
        var searchStart = text.startIndex
        while let r = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
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
