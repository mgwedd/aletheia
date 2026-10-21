import Foundation

/// The "Search results" block and the not-discussed rule for the patient-wide
/// chat. The counts are computed by `SessionSearch`; the model only quotes them.
extension Prompts {
    /// Added to `patientChat`: a topic may be called not discussed only when
    /// the search found nothing for that word, and then only as "no match found".
    static let patientSearchRule = """
        The lines starting with "- " under "Search results" are the app's own \
        counts of matches for each word of the question across the recorded \
        sessions. Quote the numbers exactly and never count yourself. Say a \
        word was not discussed only if its own line reports 0 matches, and \
        then say "no match found in the recorded sessions", never "never \
        discussed". A word's other counts do not cover a different word. \
        Similar spellings are counted separately from exact mentions; do not \
        call them exact. If a word has matches, it did come up, even where the \
        excerpts below don't show it. Wording in a session can differ from \
        the question, so a search can miss a paraphrase.
        """

    /// The block put at the top of the patient context. `shown` is how many
    /// transcript passages are in the text below. `whole` means every
    /// transcript is included; `newest` (included, of) means only the full
    /// transcripts of the newest sessions are.
    static func searchBlock(
        _ result: SessionSearch.Result, shown: Int, whole: Bool, newest: (included: Int, of: Int, cutShort: Bool)? = nil,
        layered: Bool = false, unreadableSessions: Int
    ) -> String {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        let searched = result.sessionsSearched
        let included: String
        if whole {
            included = "the full transcripts are included below"
        } else if layered {
            included = shown > 0
                ? "no transcript is included whole; below are session summaries, the summaries of the parts search points at, and the top \(plural(shown, "matching transcript passage"))"
                : "no transcript is included whole; below are session summaries and the summaries of the parts search points at"
        } else if let newest {
            included = newest.cutShort
                ? "only the newest session's transcript, cut short to fit, is included below (1 of \(plural(newest.of, "session"))); the other transcripts are not included"
                : newest.included == 0
                ? "no session transcript is included below"
                : newest.included == 1
                    ? "only the full transcript of the newest session (1 of \(newest.of)) is included below; the older transcripts are not included"
                    : "only the full transcripts of the newest \(newest.included) of \(plural(newest.of, "session")) are included below; the older transcripts are not included"
        } else {
            included = "showing the top \(plural(shown, "transcript passage"))"
        }
        var lines: [String]
        if result.terms.isEmpty {
            lines = ["Search: the question has no searchable words, so no count was made. Do not say anything was not discussed."]
            if !whole { lines.append("Not every transcript fits: \(included).") }
        } else {
            lines = ["Search results (\(plural(searched, "session")) searched):"]
            for count in result.termCounts {
                var line = "- \"\(count.term.text)\": "
                let also = (result.matchedVariants[count.term.text] ?? []).joined(separator: ", ")
                if count.exact == 0 && count.similar == 0 {
                    line += "0 matches"
                } else {
                    line += count.exact == 0 ? "no exact mentions" : plural(count.exact, "mention")
                    if count.similar > 0 {
                        line += "; \(plural(count.similar, "similar spelling")) (not exact" + (also.isEmpty ? "" : ": \(also)") + ")"
                    }
                }
                lines.append(line)
            }
            if result.totalMentions > 0 {
                lines.append("Matching passages are in \(result.sessionsWithHits) of \(plural(searched, "session")) searched; \(included).")
            } else if !whole {
                lines.append("Not every transcript fits: \(included).")
            }
            if let range = result.dateRange {
                let f = DateFormatter()
                f.dateStyle = .medium
                lines.append("Only sessions from \(f.string(from: range.start)) to \(f.string(from: range.end)) were searched.")
            }
        }
        if unreadableSessions > 0 {
            lines.append("\(unreadableSessions) session transcript\(unreadableSessions == 1 ? "" : "s") could not be read and \(unreadableSessions == 1 ? "was" : "were") not searched.")
        }
        return lines.joined(separator: "\n")
    }
}
