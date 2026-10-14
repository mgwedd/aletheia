import SwiftUI

/// One row of the progress list.
struct AIProgressLine: Equatable {
    enum State { case done, current, pending }
    let state: State
    let text: String
}

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

    /// "412 tokens" (a count of one reads "1 token").
    static func tokens(_ count: Int) -> String {
        "\(count) token\(count == 1 ? "" : "s")"
    }

    /// Seconds of reading still to go, or nil when the speed or size is unknown.
    static func readingRemaining(estimatedTokens: Int?, tokensPerSecond: Double?, elapsed: TimeInterval) -> TimeInterval? {
        guard let estimatedTokens, let tokensPerSecond, tokensPerSecond > 0 else { return nil }
        return max(0, Double(estimatedTokens) / tokensPerSecond - elapsed)
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "taking longer than estimated" }
        if seconds < 45 { return "less than a minute left" }
        return "about \(max(1, Int((seconds / 60).rounded()))) min left"
    }

    /// 0...0.95: it never claims to be finished before the first token.
    static func readingFraction(estimatedTokens: Int?, tokensPerSecond: Double?, elapsed: TimeInterval) -> Double? {
        guard let estimatedTokens, let tokensPerSecond, tokensPerSecond > 0, estimatedTokens > 0 else { return nil }
        let total = Double(estimatedTokens) / tokensPerSecond
        return min(0.95, max(0, elapsed / total))
    }

    /// The stage list for a run at `now`: read, then write.
    static func lines(_ progress: AIRunProgress, now: Date, readTokensPerSecond: Double?) -> [AIProgressLine] {
        let started = progress.startedAt ?? now
        let readDetail = progress.estimatedPromptTokens.map(estimatedTokens)
        func join(_ parts: [String?]) -> String { parts.compactMap { $0 }.joined(separator: " · ") }

        guard let firstToken = progress.firstTokenAt else {
            let elapsedNow = now.timeIntervalSince(started)
            let left = readingRemaining(
                estimatedTokens: progress.estimatedPromptTokens, tokensPerSecond: readTokensPerSecond, elapsed: elapsedNow)
            return [
                AIProgressLine(state: .current, text: join([
                    progress.readTitle, readDetail, elapsed(elapsedNow), left.map(remaining),
                ])),
                AIProgressLine(state: .pending, text: progress.writeTitle),
            ]
        }
        return [
            AIProgressLine(state: .done, text: join([
                progress.readTitle, readDetail, elapsed(firstToken.timeIntervalSince(started)),
            ])),
            AIProgressLine(state: .current, text: join([
                progress.writeTitle,
                progress.tokensWritten > 0 ? tokens(progress.tokensWritten) : nil,
                elapsed(now.timeIntervalSince(firstToken)),
            ])),
        ]
    }
}

/// Live progress for a long model call: the stages, which one is running, and
/// how long it has taken. Reading shows the prompt's size and, once this model
/// has run on this Mac, a time estimate with a bar; writing shows a token count.
struct AIProgressView: View {
    let progress: AIRunProgress
    /// Measured prompt tokens a second for this model, when known.
    var readTokensPerSecond: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let lines = AIProgressFormat.lines(progress, now: context.date, readTokensPerSecond: readTokensPerSecond)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 6) {
                        icon(for: line.state)
                        Text(line.text)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(line.state == .pending ? Theme.muted.color : Theme.text.color)
                            .monospacedDigit()
                    }
                }
                if progress.firstTokenAt == nil, let fraction = AIProgressFormat.readingFraction(
                    estimatedTokens: progress.estimatedPromptTokens,
                    tokensPerSecond: readTokensPerSecond,
                    elapsed: context.date.timeIntervalSince(progress.startedAt ?? context.date)
                ) {
                    ThemeProgressBar(value: fraction)
                        .frame(maxWidth: 240)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func icon(for state: AIProgressLine.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark").foregroundStyle(Theme.muted.color).font(Theme.Typography.caption)
                .frame(width: 14)
        case .current:
            ProgressView().controlSize(.mini).frame(width: 14)
        case .pending:
            Image(systemName: "circle").foregroundStyle(Theme.muted.color).font(Theme.Typography.caption)
                .frame(width: 14)
        }
    }
}
