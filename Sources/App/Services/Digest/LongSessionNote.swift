import Foundation

/// Writes a progress note for a session too long to send whole (#286). When the
/// transcript and prompt fit the budget, the note is written exactly as before.
/// When they don't, the model gets the session digest (the whole session,
/// summarized, built here if missing or stale) plus passages of the original
/// transcript found for each part of the note, so quotes, risk statements and
/// denials come from the words spoken and not only from a summary. What was
/// actually sent is reported through `coverage`; nothing is left out silently.
/// Focus adds a last call that checks the draft against those passages.
///
/// Runs inside the note's queue job, so the digest is built inline (not as
/// another queued job, which would wait on this one).
@MainActor
enum LongSessionNote {
    /// Characters kept free for the draft when a Focus check will follow it.
    static let draftReserve = 8_000
    /// Room for the headings around the digest and passages, and the check's wrapper.
    static let headerReserve = 1_500

    // MARK: - Run

    static func stream(
        format: ProgressNoteFormat,
        transcript: String,
        notes: String = "",
        comments: [SessionComment] = [],
        verbosity: SummaryVerbosity = .default,
        instructions: String? = nil,
        effort: AnswerEffort = .default,
        service: AssistantService,
        builder: DigestBuilder,
        sessionID: UUID,
        loadDigest: @escaping () async -> SessionDigest?,
        saveDigest: @escaping (SessionDigest) throws -> Void,
        live: @escaping DigestBuilder.Live,
        coverage: @escaping (String) -> Void
    ) -> AsyncThrowingStream<String, Error> {
        let commentLines = AssistantService.formatComments(comments)
        func prompt(_ material: String) -> String {
            Prompts.progressNote(
                format: format, transcript: material, notes: notes, comments: commentLines,
                verbosity: verbosity, instructions: instructions)
        }
        if service.fits(prompt: prompt(transcript)) {
            return service.streamProgressNote(
                format: format, transcript: transcript, notes: notes, comments: comments,
                verbosity: verbosity, instructions: instructions)
        }

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let digest = try await currentDigest(
                        transcript: transcript, service: service, builder: builder, sessionID: sessionID,
                        load: loadDigest, save: saveDigest, live: live)
                    let digestBlock = Prompts.longSessionDigest(digest.sessionDigest)
                    let reserved = service.systemPrompt.count + prompt("").count + digestBlock.count + headerReserve
                        + (effort == .focus ? draftReserve : 0)
                    let found = passages(
                        in: transcript, format: format, limit: service.budget.availableCharacters(reserving: reserved))
                    let material = Prompts.longSessionMaterial(digest: digestBlock, passages: found.text)
                    let totalLines = transcript.split(separator: "\n", omittingEmptySubsequences: true).count
                    @MainActor func label(_ checked: Bool?) -> String {
                        coverageLabel(
                            digestParts: digest.sections.count, passageLines: found.lineCount, totalLines: totalLines,
                            effort: effort, checked: checked)
                    }
                    coverage(label(nil))

                    live(nil) { $0 = AIRunProgress(readTitle: "Reading passages", writeTitle: "Writing the note", startedAt: Date()) }
                    let draftStats = StatsBox()
                    var drafter = service
                    let outer = service.report
                    drafter.report = { event in
                        if case .finished(let stats) = event { draftStats.value = stats }
                        outer?(event)
                    }
                    var draft = ""
                    for try await snapshot in drafter.streamDigest(prompt: prompt(material), task: .note) {
                        draft = snapshot
                        continuation.yield(snapshot)
                    }
                    try Task.checkCancellation()

                    if effort == .focus, !draft.isEmpty {
                        let checkPrompt = Prompts.noteCheck(draft: draft, material: material)
                        if service.fits(prompt: checkPrompt) {
                            let corrected = try await builder.runStage(
                                checkPrompt, read: "Checking", write: "Writing corrections", task: .note, service: service, live: live)
                            if !corrected.isEmpty { continuation.yield(corrected) }
                            // The truncation notice should judge the note's own read, not the check's.
                            if draftStats.value?.possiblyTruncated == true {
                                live(nil) { $0.stats = draftStats.value }
                            }
                            coverage(label(true))
                        } else {
                            coverage(label(false))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The stored digest if current, else one built now. A background build for
    /// the same session is cancelled first so the two don't both run.
    private static func currentDigest(
        transcript: String, service: AssistantService, builder: DigestBuilder, sessionID: UUID,
        load: () async -> SessionDigest?, save: (SessionDigest) throws -> Void, live: @escaping DigestBuilder.Live
    ) async throws -> SessionDigest {
        if let stored = await load() { return stored }
        builder.cancel(sessionID)
        let built = try await builder.build(
            transcript: transcript, service: service,
            live: { started, change in
                live(started) {
                    change(&$0)
                    if !$0.readTitle.hasPrefix("Building digest") { $0.readTitle = "Building digest · \($0.readTitle)" }
                }
            },
            inline: true)
        // Failing to keep the digest must not fail the note.
        try? save(built)
        return built
    }

    private final class StatsBox: @unchecked Sendable {
        var value: AIRunStats?
    }

    // MARK: - Passages

    /// Search queries, one set of words per kind of content a note section needs.
    /// Risk is always included: it must never depend on the digest alone.
    private static let riskWords = "suicide suicidal kill hurt harm safe safety overdose abuse weapon drinking alcohol drugs hopeless"
    private static let feelingWords = "feel feeling felt mood anxious anxiety sad angry worried sleep stress tired"
    private static let interventionWords = "try exercise breathe practice technique skill notice reframe thought"
    private static let planWords = "homework plan next appointment follow schedule medication"

    /// The queries for `format`'s sections (all of them for the template-free summary).
    static func topics(for format: ProgressNoteFormat) -> [String] {
        let sections = format.sections.map(\.heading)
        var out = [riskWords]
        func add(_ words: String) { if !out.contains(words) { out.append(words) } }
        if sections.isEmpty {
            [feelingWords, interventionWords, planWords].forEach(add)
        }
        for heading in sections {
            switch heading {
            case "Intervention": add(interventionWords)
            case "Plan": add(planWords)
            default: add(feelingWords)
            }
        }
        return out
    }

    /// Passages of `transcript` for each topic, best matches first and the topics
    /// taking turns, until `limit` characters are used. Each hit brings its
    /// neighbouring lines; the result is in transcript order with `[…]` between
    /// gaps. Searching is the app's own `SessionSearch` (BM25, typo tolerant).
    static func passages(in transcript: String, format: ProgressNoteFormat, limit: Int) -> (text: String, lineCount: Int) {
        guard limit > 0 else { return ("", 0) }
        let document = SessionSearch.Document(date: Date(), tag: "S1", kind: .transcript, text: transcript)
        let hits = topics(for: format).map { SessionSearch.search([document], question: $0).hits }
        var next = Array(repeating: 0, count: hits.count)
        var chosen: [Int: String] = [:]
        var used = 0
        while used < limit, hits.indices.contains(where: { next[$0] < hits[$0].count }) {
            for topic in hits.indices where next[topic] < hits[topic].count {
                let hit = hits[topic][next[topic]]
                next[topic] += 1
                let fresh = hit.context.enumerated()
                    .map { (line: hit.contextStart + $0.offset, text: $0.element) }
                    .filter { chosen[$0.line] == nil }
                let cost = fresh.reduce(0) { $0 + $1.text.count + 1 }
                if used + cost <= limit {
                    for item in fresh { chosen[item.line] = item.text }
                    used += cost
                }
            }
        }
        var lines: [String] = []
        var previous: Int?
        for index in chosen.keys.sorted() {
            if let previous, index != previous + 1 { lines.append("[…]") }
            lines.append(chosen[index] ?? "")
            previous = index
        }
        return (lines.joined(separator: "\n"), chosen.count)
    }

    // MARK: - Coverage

    /// What the note was written from, as sent. `checked` is nil when no check
    /// applies (not Focus), true once it ran, false when it was skipped.
    static func coverageLabel(digestParts: Int, passageLines: Int, totalLines: Int, effort: AnswerEffort, checked: Bool?) -> String {
        var text = "Read: a summary of the whole session (\(digestParts) parts) plus \(passageLines) of \(totalLines) transcript lines · \(effort.displayName). Details outside those lines may be missing."
        switch checked {
        case true?: text += " Checked against the passages."
        case false?: text += " Not checked: the draft was too long to check."
        case nil: break
        }
        return text
    }
}

extension Prompts {
    /// The digest, headed for the note prompt.
    static func longSessionDigest(_ digest: String) -> String {
        "Digest of the whole session (times in brackets):\n\(digest)"
    }

    /// Stands in for the transcript when it is too long to send whole.
    static func longSessionMaterial(digest: String, passages: String) -> String {
        """
        (This session is too long to include in full. Below is a digest of the whole \
        session, then passages from the original transcript chosen for each part of \
        the note; […] marks skipped lines. Use the digest for the overall picture. \
        Take quotes, risk statements and denials only from the passages. Do not add \
        detail that neither contains.)

        \(digest)

        Passages from the original transcript:
        \(passages)
        """
    }

    /// Asks the model to correct a draft note against its source material.
    static func noteCheck(draft: String, material: String) -> String {
        """
        Below are a draft clinical note and the material it was written from: a digest \
        of the whole session and passages from the original transcript. Check every \
        statement in the draft against that material.
        - Keep each statement the material supports, word for word.
        - Correct a statement the material contradicts. Remove one nothing in it supports.
        - A quote must appear in the passages exactly; otherwise remove the quote marks \
        and paraphrase it, or remove it.
        - Add nothing new. Keep the draft's headings and order.
        Return only the full corrected note, with no commentary. If nothing needs \
        changing, return the draft unchanged.

        \(transcriptLegend)

        Source material:
        \(material)

        Draft note:
        \(draft)
        """
    }
}
