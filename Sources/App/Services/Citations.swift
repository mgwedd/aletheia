import Foundation

/// One session the cross-session chat can attribute an answer to. `tag` is the
/// short handle the model is asked to cite inline (e.g. "S1", newest first);
/// `date`/`folderName` let the UI render a trustworthy, traceable source.
struct CitationSource: Equatable, Identifiable {
    let tag: String
    let date: Date
    let folderName: String

    var id: String { folderName }
}

/// The relevance-selected context handed to the model, plus the table that maps
/// each session's citation tag back to its real date/folder. `sources` lists
/// only sessions that actually appear in `text`. `unreadableSessions` counts
/// sessions whose transcript exists but could not be read (locked, damaged), so
/// the UI can warn that an answer may be incomplete.
struct PatientContext {
    let text: String
    let sources: [CitationSource]
    let unreadableSessions: Int
    let coverage: TranscriptCoverage

    init(
        text: String,
        sources: [CitationSource],
        unreadableSessions: Int = 0,
        coverage: TranscriptCoverage = TranscriptCoverage()
    ) {
        self.text = text
        self.sources = sources
        self.unreadableSessions = unreadableSessions
        self.coverage = coverage
    }
}

/// How much of the readable transcript text reached the model for one patient
/// chat question. Informational only: it describes what the retriever kept and
/// never changes what is sent. Notes and comments are not counted here; they
/// are added per session on top, up to their own cap.
struct TranscriptCoverage: Equatable {
    /// Sessions (by date) that have readable transcript text.
    var sessions: Int = 0
    /// Of those, how many have no transcript passage in the context.
    var sessionsWithoutPassages: Int = 0
    /// Characters of readable transcript text across `sessions`.
    var totalCharacters: Int = 0
    /// Characters of transcript text kept for the model.
    var includedCharacters: Int = 0

    /// True when part of the readable transcript text was left out.
    var isPartial: Bool { totalCharacters > 0 && includedCharacters < totalCharacters }

    /// Whole percent of transcript text included, rounded down, so a partial
    /// read never shows as 100%.
    var percentIncluded: Int {
        guard totalCharacters > 0 else { return 100 }
        return min(100, Int(Double(includedCharacters) / Double(totalCharacters) * 100))
    }

    /// A plain-language line for the chat sheet, or nil when everything fit.
    var notice: String? {
        guard isPartial else { return nil }
        var line = "Last answer was built from about \(percentIncluded)% of the transcript text"
        if sessionsWithoutPassages > 0 {
            line += "; \(sessionsWithoutPassages) of \(sessions) session(s) had no transcript passage included"
        }
        return line + ". Check important details in the session itself."
    }
}

/// Turns the model's inline `[S1]`-style citations into something a therapist
/// can trust: the concrete sessions cited, and a display version of the answer
/// with the tags replaced by dates and a plain-language "Sources" footer.
///
/// Pure string logic, so it's unit-tested without a model or a store.
enum Citations {
    private static let inlineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium   // e.g. "Mar 5, 2026"
        return f
    }()

    private static let footerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long      // e.g. "March 5, 2026"
        return f
    }()

    /// The sessions actually cited in `answer`, in the order the sources were
    /// provided (newest first). Tags the model invented that don't match a real
    /// session are ignored.
    static func citedSources(in answer: String, from sources: [CitationSource]) -> [CitationSource] {
        sources.filter { answer.contains("[\($0.tag)]") }
    }

    /// The answer rewritten for display: each known `[S#]` tag replaced by its
    /// session date in parentheses, and — when at least one real session was
    /// cited — a "Sources" line appended. Unknown tags are left untouched.
    static func decorate(answer: String, sources: [CitationSource]) -> String {
        var result = answer
        for source in sources {
            result = result.replacingOccurrences(
                of: "[\(source.tag)]",
                with: "(\(inlineFormatter.string(from: source.date)))"
            )
        }

        let cited = citedSources(in: answer, from: sources)
        guard !cited.isEmpty else { return result }

        let list = cited.map { footerFormatter.string(from: $0.date) }.joined(separator: "; ")
        return result + "\n\nSources: " + list
    }
}
