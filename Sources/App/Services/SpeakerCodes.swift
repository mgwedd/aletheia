import Foundation

/// A deterministic safety net for generated text: the model is told never to
/// write the transcript's `Y` / `C` speaker codes (see `Prompts.legend`), and
/// this replaces the ones that leak anyway, with "You" for `Y` and the
/// patient's first name for `C` ("the client" when unknown).
///
/// Only unambiguous shapes are touched, so "Y-axis", "Plan C", "vitamin C" and
/// initials pass through:
///   - a speaker label at the start of a line, after a bullet or bold marker,
///     or after a `[MM:SS]` stamp: `Y:`, `C~:`, `**Y**:`
///   - a lone `Y` / `C` that opens a sentence and is followed by a past-tense
///     speech or feeling verb: "Y said", "C reported" (not after "Dr." etc.)
enum SpeakerCodes {
    static func scrub(_ text: String, clientName: String) -> String {
        let first = Prompts.clientFirstName(clientName)
        let client = first.isEmpty ? "the client" : first
        func name(_ code: String) -> String { code == "Y" ? "You" : client }

        // 1. Labels: line start / bullet / quote / stamp, then the code, then a colon.
        var result = replace(
            #"((?:^|\[\d+:\d{2}(?::\d{2})?\]\s*)(?:[-*+>]\s+)?(?:\*\*)?)([YC])~?(\*\*)?:"#,
            in: text
        ) { m, ns in
            let bold = m.range(at: 3).location != NSNotFound
            return ns.substring(with: m.range(at: 1)) + name(ns.substring(with: m.range(at: 2)))
                + (bold ? "**" : "") + ":"
        }
        // 2. Sentence-opening code + speech verb.
        let verbs = "said|asked|replied|responded|stated|mentioned|reported|noted|explained|described|expressed"
            + "|agreed|shared|added|denied|acknowledged|felt|told|talked|spoke|answered|admitted|worried|wondered"
        result = replace(
            #"((?:^|[.!?]\s+|["“]\s*)(?:\*\*)?)([YC])~?(\*\*)?(\s+(?:"# + verbs + #")\b)"#,
            in: result
        ) { m, ns in
            let prefix = ns.substring(with: m.range(at: 1))
            if followsTitle(prefix: prefix, at: m.range.location, in: ns) { return nil }
            let bold = m.range(at: 3).location != NSNotFound
            return prefix + name(ns.substring(with: m.range(at: 2))) + (bold ? "**" : "")
                + ns.substring(with: m.range(at: 4))
        }
        return result
    }

    /// "Dr. Y said" / "Mr. C said": the period belongs to a title, not a sentence end.
    private static func followsTitle(prefix: String, at location: Int, in ns: NSString) -> Bool {
        guard prefix.hasPrefix("."), location > 0 else { return false }
        let word = ns.substring(to: location).split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        return ["Dr", "Mr", "Mrs", "Ms", "Prof", "St"].contains(word)
    }

    private static func replace(
        _ pattern: String, in text: String, with transform: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += transform(m, ns) ?? ns.substring(with: m.range)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
