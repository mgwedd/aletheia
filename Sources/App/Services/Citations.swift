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
/// each session's citation tag back to its real date/folder.
struct PatientContext {
    let text: String
    let sources: [CitationSource]
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
