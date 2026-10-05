import Foundation

/// Decouples how fast text *arrives* from how fast it's *revealed*, so streamed
/// answers read as a calm, even flow instead of bursty token clumps or dizzying
/// character machine-gunning.
///
/// It's a pure function of "how much is shown" and "the full text so far": each
/// display tick advances the shown length by a small chunk, **snapped forward
/// to the next word boundary**, and reveals faster when it's fallen far behind
/// the model (adaptive) so it never lags yet never stutters. The view calls
/// `nextCount` on a steady timer and shows `target.prefix(nextCount)`.
enum StreamSmoother {
    /// The character count to display next, given how many are shown now and
    /// the full target text so far.
    /// - baseChunk: minimum characters revealed per tick.
    /// - catchUpDivisor: larger backlog → bigger steps (backlog / divisor).
    /// - maxSnap: how far past the chunk we'll scan to land on a word boundary.
    static func nextCount(
        displayed: Int,
        target: String,
        baseChunk: Int = 4,
        catchUpDivisor: Int = 8,
        maxSnap: Int = 14
    ) -> Int {
        let chars = Array(target)
        let total = chars.count
        guard displayed < total else { return total }
        let start = max(0, displayed)

        let remaining = total - start
        let chunk = max(baseChunk, remaining / max(1, catchUpDivisor))
        var end = min(start + chunk, total)

        // Snap forward to the end of the current word (next whitespace) for a
        // calmer, word-by-word feel — but don't scan forever.
        while end < total, !chars[end - 1].isWhitespace, (end - (start + chunk)) < maxSnap {
            end += 1
        }
        return end
    }

    /// Convenience: the displayed prefix string for a given count.
    static func prefix(of target: String, count: Int) -> String {
        let chars = Array(target)
        return String(chars.prefix(max(0, min(count, chars.count))))
    }
}
