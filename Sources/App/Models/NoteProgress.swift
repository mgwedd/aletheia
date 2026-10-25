import Foundation

/// The Notes pane's own wording, in one place so screens and tests agree.
enum NoteWords {
    static func emptyTitle(format: ProgressNoteFormat) -> String { "No \(format.shortName) note yet" }
    static func generateButton(format: ProgressNoteFormat) -> String { "Generate \(format.shortName) note" }
    /// The Length menu's button: "Length: Natural · Normal".
    static func lengthLabel(length: SummaryVerbosity, effort: AnswerEffort) -> String {
        "Length: \(length.displayName) \u{00B7} \(effort.displayName)"
    }
    /// What the Length menu offers: the lengths, then the AI effort levels.
    static var lengthChoices: [String] { SummaryVerbosity.allCases.map(\.displayName) }
    static var effortChoices: [String] { AnswerEffort.allCases.map(\.displayName) }
    static let lengthTitle = "Length"
    static let outdatedMessage = "Outdated: the transcript has changed since this note was generated."
    static let replaceEditedTitle = "Replace your edited note?"
    static func editPromptItem(format: ProgressNoteFormat, customized: Bool) -> String {
        "Edit \(format.shortName) Prompt…\(customized ? " (customized)" : "")"
    }
}

/// The note pane's progress while a note is generated: one status line
/// and a bar, worked out from the run's live `AIRunProgress`. Pure functions,
/// so they can be tested without a clock or a view.
///
/// A note is one model call when the session fits; a long session first
/// builds its digest (a call per section, then merges), then writes the draft,
/// then may check it. Each phase gets a band of the bar, and the call in flight
/// moves through its band: reading fills the first half, writing the second.
@MainActor
enum NoteProgress {
    /// "Generating summary", "Generating SOAP note".
    static func title(for format: ProgressNoteFormat) -> String {
        format == .narrative ? "Generating summary" : "Generating \(format.shortName) note"
    }

    /// The line over the bar: the shared status line, led by the note's title
    /// while the model reads ("Generating SOAP note. Reading the session… · 0:12").
    static func statusLine(title: String, _ progress: AIRunProgress, now: Date) -> String {
        var led = progress
        led.lead = title
        return AIProgressFormat.statusLine(led, now: now)
    }

    /// Where the bar ends for each phase. The draft starts at 0 when no digest
    /// was built in this run (a short session, or a digest already saved).
    static let digestEnd = 0.6
    static let draftEnd = 0.9
    static let checkEnd = 0.97

    /// 0..<1 for the whole run at `now`. Never 1: the pane swaps to the note when it ends.
    static func fraction(_ progress: AIRunProgress, now: Date, speed: ModelSpeed?) -> Double {
        let digestPrefix = DigestBuilder.activityTitle
        if progress.readTitle.hasPrefix(digestPrefix) {
            let call = callFraction(progress, now: now, readTokensPerSecond: speed?.read,
                                    expectedOutputTokens: speed?.expectedOutput(for: .digest))
            guard let steps = progress.steps, steps.total > 0 else { return digestEnd * call }
            let overall = (Double(steps.done) + call) / Double(steps.total)
            return digestEnd * min(max(overall, 0), 1)
        }
        let call = callFraction(progress, now: now, readTokensPerSecond: speed?.read,
                                expectedOutputTokens: speed?.expectedOutput(for: .note))
        if progress.readTitle == LongSessionNote.checkTitle {
            return draftEnd + (checkEnd - draftEnd) * call
        }
        let builtDigest = progress.steps != nil
            || progress.completedStages.contains { $0.hasPrefix(digestPrefix) }
        let start = builtDigest ? digestEnd : 0
        return start + (draftEnd - start) * call
    }

    /// 0...0.975 for the call in flight: reading is 0..<0.5, writing 0.5..<1.
    /// With a measured speed (or a typical reply length) the bar follows it;
    /// without one it creeps toward the end of the half and never reaches it.
    static func callFraction(
        _ progress: AIRunProgress, now: Date, readTokensPerSecond: Double?, expectedOutputTokens: Int?
    ) -> Double {
        guard progress.firstTokenAt != nil else {
            let elapsed = now.timeIntervalSince(progress.startedAt ?? now)
            let read = AIProgressFormat.readingFraction(
                estimatedTokens: progress.estimatedPromptTokens, tokensPerSecond: readTokensPerSecond, elapsed: elapsed)
                ?? creep(elapsed, scale: 30)
            return 0.5 * read
        }
        let written = Double(progress.tokensWritten)
        let write: Double
        if let expectedOutputTokens, expectedOutputTokens > 0 {
            write = min(0.95, written / Double(expectedOutputTokens))
        } else {
            write = creep(written, scale: 300)
        }
        return 0.5 + 0.5 * write
    }

    /// 0 at 0, rising toward (never reaching) 0.95; about two-thirds of the way at `scale`.
    static func creep(_ value: Double, scale: Double) -> Double {
        guard value > 0, scale > 0 else { return 0 }
        return 0.95 * (1 - exp(-value / scale))
    }
}

/// Keeps a bar from moving backwards when an estimate is revised down (a
/// stage's count resets, or a digest finds it needs another merge).
final class ProgressHighWater {
    private(set) var peak = 0.0

    func clamp(_ value: Double) -> Double {
        peak = max(peak, value)
        return peak
    }
}
