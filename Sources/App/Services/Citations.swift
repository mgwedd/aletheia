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

/// What one patient chat question was built from, counted from what was
/// actually put in the prompt, never from what was meant to be. Unreadable
/// sessions are not counted as read.
struct TranscriptCoverage: Equatable {
    /// Sessions (by date) with readable transcript text inside the question's date range.
    var transcriptSessions: Int = 0
    /// Of those, how many have transcript text in the context.
    var sessionsWithPassages: Int = 0
    /// Sessions whose notes, generated notes or comments are in the context.
    var notesSessions: Int = 0
    /// Sessions whose transcript exists but could not be read.
    var unreadableSessions: Int = 0
    /// Exact search mentions across every searched document (see `SessionSearch.Result`).
    var mentions: Int = 0
    /// Matches on a similar spelling, counted apart from `mentions`.
    var similarMentions: Int = 0
    /// The question had words to search for.
    var searched = false
    /// Every session's whole transcript was sent; nothing was left out.
    var wholeTranscripts = false
    /// What was sent are whole transcripts (the newest that fit), not search passages.
    var fullTexts = false
    /// Sessions whose notes or comments were cut short or left out to fit.
    var notesCutSessions: Int = 0

    /// A plain-language line for the chat sheet, or nil when nothing was read.
    var label: String? {
        func sessions(_ n: Int) -> String { "\(n) session\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if notesSessions > 0 || notesCutSessions > 0 {
            let cut = notesCutSessions > 0 ? " (cut short or left out for \(sessions(notesCutSessions)))" : ""
            parts.append("notes and comments from \(sessions(notesSessions))" + cut)
        }
        if transcriptSessions > 0 {
            var search = ""
            if searched {
                search = " (\(mentions) match\(mentions == 1 ? "" : "es") for your words"
                search += similarMentions > 0 ? ", \(similarMentions) more with similar spelling)" : ")"
            }
            if wholeTranscripts {
                parts.append("full transcripts of \(sessions(sessionsWithPassages))" + search)
            } else if fullTexts {
                let read = sessionsWithPassages == 0
                    ? "no full transcripts (the newest session is too long to fit)"
                    : sessionsWithPassages == 1
                        ? "the full transcript of the newest session (1 of \(sessions(transcriptSessions)))"
                        : "full transcripts of the newest \(sessionsWithPassages) of \(sessions(transcriptSessions))"
                parts.append(read + search)
            } else {
                parts.append("transcript passages from \(sessionsWithPassages) of \(sessions(transcriptSessions))" + search)
            }
        }
        if unreadableSessions > 0 { parts.append("\(sessions(unreadableSessions)) could not be read, so answers may be incomplete") }
        return parts.isEmpty ? nil : "Read: " + parts.joined(separator: " · ")
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

    /// What the chat shows for a finished answer: decorated when the citations
    /// module is in this build, the raw answer otherwise. Pulled out of the view
    /// so the gate is testable.
    static func display(answer: String, sources: [CitationSource], enabled: Bool) -> String {
        enabled ? decorate(answer: answer, sources: sources) : answer
    }
}
