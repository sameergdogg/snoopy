import SwiftUI
import SnoopyCore

/// Activity timeline above the request list: one stacked bar per time slice, coloured by
/// outcome, with drag-to-brush that scopes the list to a time range.
///
/// The whole strip is a single `Canvas`. Rendering each request as a SwiftUI view would
/// recreate the per-row cost this pass exists to remove.
struct TimelineStrip: View {
    @EnvironmentObject var store: CaptureStore

    @State private var dragStart: CGFloat?
    @State private var dragCurrent: CGFloat?

    private static let barsHeight: CGFloat = 52
    private static let axisHeight: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            GeometryReader { geo in
                canvas(width: geo.size.width)
                    .contentShape(Rectangle())
                    .gesture(brush(width: geo.size.width))
            }
            .frame(height: Self.barsHeight + Self.axisHeight)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Timeline").font(.caption).bold().foregroundStyle(.secondary)
            if let r = store.selectedRange {
                Text("\(Exchange.clockText(r.lowerBound)) – \(Exchange.clockText(r.upperBound))")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                Button { store.selectedRange = nil } label: {
                    Label("Clear range", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption2)
            } else if store.timelineSpan != nil {
                Text("drag to scope the list to a time range")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            // Retained bytes, dropped rows and the live row window moved to the status bar,
            // where they belong together and there is room to say what they mean.
            if store.matchCount > 0 {
                Text("\(store.matchCount.formatted()) in view")
                    .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Canvas

    private func canvas(width: CGFloat) -> some View {
        let buckets = store.timeline
        let span = store.timelineSpan
        let selection = selectionRect(width: width)

        return Canvas { ctx, size in
            let barsRect = CGRect(x: 0, y: 0, width: size.width, height: Self.barsHeight)
            ctx.fill(Path(roundedRect: barsRect, cornerRadius: 4), with: .color(.gray.opacity(0.08)))

            guard !buckets.isEmpty, let span else {
                ctx.draw(ctx.resolve(Text("No traffic yet").font(.caption2).foregroundStyle(.tertiary)),
                         at: CGPoint(x: size.width / 2, y: Self.barsHeight / 2))
                return
            }

            let peak = max(1, buckets.map(\.total).max() ?? 1)
            let slot = size.width / CGFloat(buckets.count)
            let barW = max(1, slot - 1)

            for b in buckets where b.total > 0 {
                let x = CGFloat(b.index) * slot
                var y = Self.barsHeight
                // Stacked bottom-up, worst outcome on top so failures stay visible.
                for (count, color) in [(b.ok, Color.green), (b.pending, Color.gray),
                                       (b.warn, Color.orange), (b.error, Color.red)] where count > 0 {
                    let h = (CGFloat(count) / CGFloat(peak)) * (Self.barsHeight - 2)
                    y -= h
                    ctx.fill(Path(CGRect(x: x, y: y, width: barW, height: h)),
                             with: .color(color.opacity(0.85)))
                }
            }

            // Dim everything outside the brushed range.
            if let sel = selection {
                let dim = GraphicsContext.Shading.color(.black.opacity(0.35))
                ctx.fill(Path(CGRect(x: 0, y: 0, width: sel.minX, height: Self.barsHeight)), with: dim)
                ctx.fill(Path(CGRect(x: sel.maxX, y: 0, width: size.width - sel.maxX, height: Self.barsHeight)), with: dim)
                var edge = Path()
                edge.addRect(CGRect(x: sel.minX, y: 0, width: sel.width, height: Self.barsHeight))
                ctx.stroke(edge, with: .color(.accentColor), lineWidth: 1.5)
            }

            drawAxis(ctx, size: size, span: span)
        }
    }

    private func drawAxis(_ ctx: GraphicsContext, size: CGSize, span: ClosedRange<Date>) {
        let y = Self.barsHeight + Self.axisHeight / 2
        let ticks = 4
        for i in 0...ticks {
            let f = CGFloat(i) / CGFloat(ticks)
            let t = span.lowerBound.addingTimeInterval(
                span.upperBound.timeIntervalSince(span.lowerBound) * Double(f))
            let label = ctx.resolve(Text(Exchange.clockText(t).prefix(8))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary))
            let w = label.measure(in: size).width
            // Keep the first and last labels inside the strip instead of clipping them.
            let x = min(max(f * size.width, w / 2), size.width - w / 2)
            ctx.draw(label, at: CGPoint(x: x, y: y))
        }
    }

    // MARK: Brushing

    private func selectionRect(width: CGFloat) -> CGRect? {
        if let a = dragStart, let b = dragCurrent {
            return CGRect(x: min(a, b), y: 0, width: abs(b - a), height: Self.barsHeight)
        }
        guard let sel = store.selectedRange, let span = store.timelineSpan else { return nil }
        let total = span.upperBound.timeIntervalSince(span.lowerBound)
        guard total > 0 else { return nil }
        let x0 = CGFloat(sel.lowerBound.timeIntervalSince(span.lowerBound) / total) * width
        let x1 = CGFloat(sel.upperBound.timeIntervalSince(span.lowerBound) / total) * width
        return CGRect(x: max(0, x0), y: 0, width: min(width, x1) - max(0, x0), height: Self.barsHeight)
    }

    private func brush(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragStart == nil { dragStart = clamp(g.startLocation.x, width) }
                dragCurrent = clamp(g.location.x, width)
            }
            .onEnded { g in
                defer { dragStart = nil; dragCurrent = nil }
                guard let a = dragStart, let span = store.timelineSpan else { return }
                let b = clamp(g.location.x, width)
                // A click (rather than a drag) clears the range.
                guard abs(b - a) > 3 else { store.selectedRange = nil; return }
                let total = span.upperBound.timeIntervalSince(span.lowerBound)
                func date(_ x: CGFloat) -> Date {
                    span.lowerBound.addingTimeInterval(total * Double(x / max(1, width)))
                }
                store.selectedRange = date(min(a, b))...date(max(a, b))
            }
    }

    private func clamp(_ x: CGFloat, _ width: CGFloat) -> CGFloat { min(max(0, x), width) }
}
