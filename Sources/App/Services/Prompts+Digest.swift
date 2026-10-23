import Foundation

extension Prompts {
    /// Bump when the digest prompts change meaningfully: stored digests carry it,
    /// and a different value marks them stale so they are rebuilt.
    static let digestVersion = 1

    /// Compact notes on one stretch of a session, tied to its time range.
    static func sectionDigest(text: String, anchor: String, clientName: String = "") -> String {
        """
        Below is one section of a therapy session transcript, covering \(anchor). \
        Write compact digest notes for it, for a clinician who will use them to \
        find their way back to the original. Begin with the line "\(anchor)". Then \
        list, as short bullets:
        - Topics discussed
        - The client's key statements (a short quote only when the exact words matter)
        - Interventions or techniques the therapist used
        - Affect and how it changed
        - Risk flags: self-harm, harm to others, abuse, safety, and any mention of \
        alcohol or drug use. Also record when the therapist asked about risk and the \
        client denied it. Write "Risk: none noted" only if none of this appears.
        - Follow-ups, homework or plans agreed

        Use only what is in this text. Do not infer, diagnose or add anything the \
        speakers did not say. Leave out a heading if the section has nothing for it. \
        Keep it under 1,200 characters.

        \(materialRule)

        \(legend(clientName: clientName))

        Transcript section \(anchor):
        \(UntrustedText(.transcript, TranscriptCompactor.compact(text)).rendered)
        """
    }

    /// Merges section digests into one digest of the whole session.
    static func sessionDigest(sections: [(anchor: String, digest: String)], clientName: String = "") -> String {
        let body = sections.map { "\($0.anchor)\n\($0.digest)" }.joined(separator: "\n\n")
        return """
        Below are digest notes for consecutive sections of one therapy session. \
        Merge them into a single digest of the whole session, at most 2,000 \
        characters. Cover the main topics, the client's key statements, \
        interventions, affect over time, risk flags (including any alcohol or drug \
        use, and any denial of self-harm) and follow-ups. End every bullet with the \
        time range it came from, copied from the notes, such as "- Poor sleep, \
        about four hours a night [0:00–9:30]", so the reader can find it in the \
        transcript. Write "Risk: none noted" only if the notes flag nothing.

        Refer to the therapist as "You" and to the client as \(clientRef(clientName)), as the notes do.

        Use only what is in the notes. Do not infer, diagnose or add anything \
        they do not say. Do not drop a risk flag to save space.

        \(materialRule)

        Section digests:
        \(UntrustedText(.digest, body).rendered)
        """
    }
}
