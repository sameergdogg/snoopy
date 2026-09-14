import Foundation

/// A large body of text split into independently-renderable chunks.
///
/// The viewer used to hand a whole pretty-printed payload to a single SwiftUI `Text` inside
/// a scroll view with an unbounded height proposal. TextKit then laid out every line of it,
/// synchronously, on the main thread, every time the pane appeared — which is why a response
/// with a large line count froze the window rather than displaying slowly. Cost scaled with
/// the size of the document instead of the size of the window.
///
/// Splitting into chunks lets the viewer put them in a `LazyVStack`, so layout cost scales
/// with what is actually on screen. Two details matter for real payloads:
///
/// - Minified JSON is one enormous line. Chunking by line alone would put the entire
///   document back into one `Text`, so over-long lines are hard-wrapped into segments.
/// - Line numbers are precomputed per chunk; deriving them at render time would require
///   counting newlines in every preceding chunk.
public struct TextDocument: Sendable, Hashable {
    public struct Chunk: Identifiable, Sendable, Hashable {
        public let id: Int
        public let text: String
        /// 1-based line number of this chunk's first line, for the gutter.
        public let firstLine: Int
        public let lineCount: Int
    }

    public let chunks: [Chunk]
    public let lineCount: Int
    /// True when the source was longer than `maxBytes` and the tail was dropped.
    public let truncated: Bool
    public let byteCount: Int

    public var isEmpty: Bool { chunks.isEmpty }

    /// Lines per chunk. Small enough that one chunk lays out imperceptibly, large enough
    /// that a 100k-line document is a few hundred views rather than 100k.
    public static let linesPerChunk = 120
    /// Long lines are wrapped at this many characters so a minified payload still chunks.
    public static let maxLineLength = 2_000
    /// Ceiling on text held for display. Rendering is lazy now, so this is about memory,
    /// not layout time — it can be far larger than the old 512 KB display clip.
    public static let defaultMaxBytes = 8 * 1024 * 1024

    public init(_ source: String, maxBytes: Int = TextDocument.defaultMaxBytes) {
        let (clipped, wasTruncated) = TextDocument.clip(source, maxBytes: maxBytes)
        var chunks: [Chunk] = []
        var pending: [Substring] = []
        var pendingFirstLine = 1
        var line = 1
        var total = 0

        func flush() {
            guard !pending.isEmpty else { return }
            chunks.append(Chunk(id: chunks.count,
                                text: pending.joined(separator: "\n"),
                                firstLine: pendingFirstLine,
                                lineCount: pending.count))
            pending.removeAll(keepingCapacity: true)
        }

        for rawLine in clipped.split(separator: "\n", omittingEmptySubsequences: false) {
            // Hard-wrap over-long lines; a single 5 MB minified line must not become one chunk.
            for segment in TextDocument.wrap(rawLine, at: TextDocument.maxLineLength) {
                if pending.isEmpty { pendingFirstLine = line }
                pending.append(segment)
                total += 1
                if pending.count >= TextDocument.linesPerChunk { flush() }
            }
            line += 1
        }
        flush()

        self.chunks = chunks
        self.lineCount = total
        self.truncated = wasTruncated
        self.byteCount = clipped.utf8.count
    }

    private static func wrap(_ line: Substring, at limit: Int) -> [Substring] {
        guard line.count > limit else { return [line] }
        var out: [Substring] = []
        var i = line.startIndex
        while i < line.endIndex {
            let j = line.index(i, offsetBy: limit, limitedBy: line.endIndex) ?? line.endIndex
            out.append(line[i..<j])
            i = j
        }
        return out
    }

    /// Clips to a UTF-8 *byte* budget on a Character boundary.
    ///
    /// The previous version compared `utf8.count` against the cap but cut with
    /// `String.prefix`, which counts Characters — so a cap of 512 KB let through up to
    /// 512k characters, several megabytes for non-ASCII text, on exactly the payloads
    /// that were already too slow to lay out.
    public static func clip(_ s: String, maxBytes: Int) -> (String, Bool) {
        guard s.utf8.count > maxBytes else { return (s, false) }
        let utf8 = s.utf8
        var probe = utf8.index(utf8.startIndex, offsetBy: maxBytes)
        // Back off to the nearest Character boundary so we never split a grapheme.
        while probe > utf8.startIndex, String.Index(probe, within: s) == nil {
            probe = utf8.index(before: probe)
        }
        guard let cut = String.Index(probe, within: s) else { return ("", true) }
        return (String(s[s.startIndex..<cut]), true)
    }
}
