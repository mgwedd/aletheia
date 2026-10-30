import SwiftUI
/// The wording and arithmetic behind `AIProgressView`, as pure functions so
/// they can be tested without a clock or a view.
enum AIProgressFormat {
    /// "0:42", "12:05".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// "~800 tokens", "~31K tokens".
    static func estimatedTokens(_ count: Int) -> String {
        count < 1000 ? "~\(count) tokens" : "~\(Int((Double(count) / 1000).rounded()))K tokens"
    }

    /// 0...0.95: it never claims to be finished before the first token.
    static func readingFraction(estimatedTokens: Int?, tokensPerSecond: Double?, elapsed: TimeInterval) -> Double? {
        guard let estimatedTokens, let tokensPerSecond, tokensPerSecond > 0, estimatedTokens > 0 else { return nil }
        let total = Double(estimatedTokens) / tokensPerSecond
        return min(0.95, max(0, elapsed / total))
    }

    /// The words for "Analyzing …": up to two of the question's search terms that
    /// occur in `material`, in the order asked. Plain matching, no model.
    static func analyzingWords(question: String, in material: String) -> String? {
        var words: [String] = []
        for term in SessionSearch.terms(from: question).prefix(4) {
            let text = term.text
            let whole = "\\b" + NSRegularExpression.escapedPattern(for: text) + "\\b"
            guard !text.isEmpty,
                  material.range(of: whole, options: TextSearch.compareOptions.union(.regularExpression)) != nil
            else { continue }
            words.append(contentsOf: term.words.prefix(2 - words.count))
            if words.count >= 2 { break }
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// The status line for work before any model runs: "Searching 12 sessions
    /// for “dream”… · 0:03".
    static func busyLine(_ notice: String, since: Date, now: Date) -> String {
        "\(notice) · \(elapsed(now.timeIntervalSince(since)))"
    }

    /// The one status line for a run at `now`: the stage, then the time since
    /// the run began. It replaces itself as the run moves on.
    ///
    /// Reading: "1 mention, in the Oct 13 session. Reading what was gathered… · 0:12"
    /// (the lead, when retrieval set one). Writing: "Writing the answer… · 0:41".
    static func statusLine(_ progress: AIRunProgress, now: Date) -> String {
        let elapsed = elapsed(now.timeIntervalSince(progress.runStartedAt ?? progress.startedAt ?? now))
        guard progress.firstTokenAt == nil else { return "\(progress.writeTitle)… · \(elapsed)" }
        if let prefill = progress.prefill {
            if prefill.complete { return "Preparing the answer · \(elapsed)" }
            if prefill.total > 1 {
                if prefill.part >= prefill.total, let words = progress.analyzing, !words.isEmpty {
                    return "Analyzing \(words) · \(elapsed)"
                }
                let reading = "\(progress.readTitle) · part \(prefill.part) of \(prefill.total)"
                return "\([progress.lead, reading].compactMap { $0 }.joined(separator: ". ")) · \(elapsed)"
            }
        }
        let activity = [progress.lead, progress.readTitle + "…"].compactMap { $0 }.joined(separator: ". ")
        return "\(activity) · \(elapsed)"
    }
}

/// Live progress for a model call: one muted line that replaces itself (a
/// pulsing dot, what is happening, and a live elapsed counter). Every surface
/// that runs a model shows its progress through this view; a caller with an
/// overall position adds its own bar.
struct AIProgressView: View {
    let progress: AIRunProgress

    var body: some View {
        LiveTimeline { now in
            AIStatusLineView(text: AIProgressFormat.statusLine(progress, now: now))
        }
    }
}

/// The status line's look, for a line worked out elsewhere (search, before
/// any model runs): a pulsing dot and one muted line.
struct AIStatusLineView: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            PulsingDot()
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// A small dot that breathes while work runs; still under Reduce Motion.
private struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var dim = false
    private var reduceMotion: Bool { QuietUI.reducesMotion(systemReduceMotion) }

    var body: some View {
        Circle()
            .fill(Theme.accent.color)
            .frame(width: 6, height: 6)
            .opacity(dim && !reduceMotion ? 0.3 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .frame(width: 14)
            .accessibilityHidden(true)
            .onAppear { dim = true }
    }
}
