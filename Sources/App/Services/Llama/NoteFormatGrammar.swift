import Foundation

/// GBNF grammar generation for the structured progress-note formats.
///
/// GBNF (the grammar format llama.cpp uses for constrained decoding) lets the
/// local engine's sampler *only* emit tokens the grammar allows, so a structured
/// note comes back already shaped — the exact `## Heading` sections, in order —
/// with no post-hoc repair pass. The rest of the app talks to this through the
/// `LocalLLMGrammar` carrier on `LocalLLMRequest`; nothing here calls a model, so
/// the generator is pure and unit-tested in every build tier.
///
/// The grammar is derived from `ProgressNoteFormat.sections`, the single source
/// of truth the prompt builder and exporter already use, so the constrained
/// output and the prompt can never drift apart.
///
/// Shape produced (SOAP shown):
/// ```gbnf
/// root ::= sec0 sec1 sec2 sec3
/// sec0 ::= "## Subjective\n" body
/// sec1 ::= "\n\n## Objective\n" body
/// sec2 ::= "\n\n## Assessment\n" body
/// sec3 ::= "\n\n## Plan\n" body
/// body ::= ( [^#] | "#" [^#] )*
/// ```
/// The `body` rule matches any text that never contains the two-character
/// sequence `##`, so the *only* `##` in the output are the section headings the
/// `secN` rules emit — that's what guarantees the note parses back into its
/// sections cleanly.
extension ProgressNoteFormat {
    /// A GBNF grammar constraining a draft of this note to its exact sections in
    /// order, or `nil` for `.narrative` (free text is intentionally unconstrained).
    var grammar: LocalLLMGrammar? {
        let secs = sections
        guard !secs.isEmpty else { return nil }

        var rules: [String] = []
        let sectionRefs = secs.indices.map { "sec\($0)" }.joined(separator: " ")
        rules.append("root ::= \(sectionRefs)")

        for (index, section) in secs.enumerated() {
            let heading = Self.escapedForGBNF(section.heading)
            // The first section opens the note; each later one is preceded by a
            // blank line, matching the Markdown the prompt asks the model to write.
            let literal = index == 0
                ? "\"## \(heading)\\n\""
                : "\"\\n\\n## \(heading)\\n\""
            rules.append("sec\(index) ::= \(literal) body")
        }

        // Any run of characters with no `##`, so headings are the only `##`.
        rules.append("body ::= ( [^#] | \"#\" [^#] )*")

        return LocalLLMGrammar(label: shortName, gbnf: rules.joined(separator: "\n") + "\n")
    }

    /// Escapes a heading for use inside a GBNF double-quoted string literal.
    /// Headings are plain words today; this keeps the generator correct if one
    /// ever gains a quote or backslash.
    static func escapedForGBNF(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

extension LocalLLMRequest {
    /// Assembles a deterministic local-LLM request that drafts a progress note in
    /// `format`: the existing prompt from `Prompts.progressNote`, plus the format's
    /// GBNF grammar so a structured note is grammar-constrained end to end. This is
    /// the single call site the embedded engine uses once it's wired (see the LLM
    /// epic) — narrative notes carry no grammar and decode freely.
    static func progressNote(
        format: ProgressNoteFormat,
        transcript: String,
        notes: String = "",
        comments: [String] = [],
        system: String = ""
    ) -> LocalLLMRequest {
        LocalLLMRequest(
            system: system,
            prompt: Prompts.progressNote(
                format: format,
                transcript: transcript,
                notes: notes,
                comments: comments
            ),
            sampling: .deterministic,
            grammar: format.grammar
        )
    }
}
