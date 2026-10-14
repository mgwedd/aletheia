import Foundation

/// The "Search results" block and the not-discussed rule for the patient-wide
/// chat. The counts are computed by `SessionSearch`; the model only quotes them.
extension Prompts {
    /// Added to `patientChat`: a topic may be called not discussed only when
    /// the search found nothing, and then only as "no match found".
    static let patientSearchRule = """
        The line starting "Search for" is the app's own count of matches for \
        the question's words across the recorded sessions. Quote its numbers \
        exactly and never count yourself. Say something was not discussed \
        only if that line reports 0 matches, and then say "no match found in \
        the recorded sessions", never "never discussed". If it reports \
        matches, the topic did come up, even where the excerpts below don't \
        show it. Wording in a session can differ from the question, so a \
        search can miss a paraphrase.
        """

    /// The block put at the top of the patient context. `shown` is how many
    /// transcript passages are in the text below, or all of them if `whole`.
    static func searchBlock(
        _ result: SessionSearch.Result, shown: Int, whole: Bool, unreadableSessions: Int
    ) -> String {
        var lines: [String]
        if result.terms.isEmpty {
            lines = ["Search: the question has no searchable words, so no count was made. Do not say anything was not discussed."]
        } else {
            let names = result.terms.map { term -> String in
                let also = result.matchedVariants[term.text] ?? []
                return "\"\(term.text)\"" + (also.isEmpty ? "" : " (also matched: \(also.joined(separator: ", ")))")
            }.joined(separator: ", ")
            let searched = result.sessionsSearched
            var line = "Search for \(names): "
            if result.totalMentions == 0 {
                line += "0 matches in \(searched) session\(searched == 1 ? "" : "s") searched."
            } else {
                let mentions = result.totalMentions
                line += "\(mentions) mention\(mentions == 1 ? "" : "s") in \(result.sessionsWithHits) of \(searched) session\(searched == 1 ? "" : "s") searched; "
                line += whole ? "the full transcripts are included below." : "showing the top \(shown) transcript passage\(shown == 1 ? "" : "s")."
            }
            lines = [line]
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
