import Foundation

/// Writes a progress note for a session too long to send whole (#286). When the
/// transcript and prompt fit the budget, the note is written exactly as before.
/// When they don't, the model gets the session digest (the whole session,
/// summarized, built here if missing or stale) plus passages of the original
/// transcript: lines about risk first, then lines found for each part of the
/// note, so quotes, risk statements and denials come from the words spoken and
/// not only from a summary. What was actually sent is reported through
/// `coverage`; nothing is left out silently. Focus adds a last call that checks
/// the draft against those passages.
///
/// Runs inside the note's queue job, so the digest is built inline (not as
/// another queued job, which would wait on this one).
@MainActor
enum LongSessionNote {
    /// Characters kept free for the draft when a Focus check will follow it
    /// (at most a third of the material room).
    static let draftReserve = 8_000
    /// Room for the headings around the digest and passages, and the check's wrapper.
    static let headerReserve = 1_500
    /// Characters of passages set aside for risk lines before anything else.
    static let riskReserve = 3_000
    /// Below this many characters of passages, Focus skips its check instead.
    static let passageFloor = 4_000
    /// The most of the material room the digest may take.
    static let digestShare = 2_500

    /// How the Focus check ended.
    enum CheckOutcome: Equatable {
        case ran, noRoom, tooLong, failed, incomplete, stopped

        var text: String {
            switch self {
            case .ran: return "Checked against the passages."
            case .noRoom: return "Not checked: not enough room on this Mac for the check."
            case .tooLong: return "Not checked: the draft was too long to check."
            case .failed: return "The check didn't run (it failed), so this is the unchecked draft."
            case .incomplete: return "The check's result looked incomplete, so this is the unchecked draft."
            case .stopped: return "Stopped before the check finished; this is the unchecked draft."
            }
        }
    }

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

                    // Room for material, after the instructions, the note's own wrapper and headings.
                    let total = service.budget.availableCharacters(
                        reserving: service.systemPrompt.count + prompt("").count + headerReserve)
                    var room = total
                    var plannedCheck: CheckOutcome?
                    if effort == .focus {
                        let reserve = min(draftReserve, total / 3)
                        let digestSize = min(digest.sessionDigest.count, digestShare)
                        if total - reserve - digestSize < passageFloor {
                            plannedCheck = .noRoom
                        } else {
                            room = total - reserve
                        }
                    }
                    // Risk lines get their room first; the digest shrinks to fit what is left.
                    let riskLimit = min(riskReserve, room / 3)
                    let (digestBlock, shortened) = fit(Prompts.longSessionDigest(digest.sessionDigest), to: room - riskLimit)
                    let digestText = digestBlock
                    let transcriptCopy = transcript
                    let limit = room - digestText.count
                    let found = await Task.detached {
                        passages(in: transcriptCopy, format: format, limit: limit, riskLimit: riskLimit)
                    }.value
                    let material = Prompts.longSessionMaterial(digest: digestText, passages: found.text)
                    let totalLines = nonBlankLines(transcript).count
                    @MainActor func label(_ check: CheckOutcome?) -> String {
                        coverageLabel(
                            digestParts: digest.sections.count, digestShortened: shortened, passageLines: found.lineCount,
                            totalLines: totalLines, effort: effort, check: check)
                    }
                    coverage(label(plannedCheck))

                    // The draft, streamed into the pane as it is written.
                    let draftStats = StatsBox()
                    var drafter = service
                    let outer = service.report
                    drafter.report = { event in
                        if case .finished(let stats) = event { draftStats.value = stats }
                        outer?(event)
                    }
                    let draft = try await builder.runStage(
                        prompt(material), read: "Reading passages", write: "Writing the note", task: .note,
                        service: drafter, live: live, onSnapshot: { continuation.yield($0) })
                    try Task.checkCancellation()

                    if effort == .focus, plannedCheck == nil, !draft.isEmpty {
                        let outcome = await check(
                            draft: draft, material: material, format: format, service: service,
                            builder: builder, live: live, accept: { continuation.yield($0) })
                        // The truncation notice judges the note's own read, not the check's. A new
                        // start time makes any late event from the check stage drop.
                        live(nil) { $0.stats = draftStats.value; $0.startedAt = Date() }
                        coverage(label(outcome))
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

    /// One call that corrects `draft` against `material`. The corrected note is
    /// handed to `accept` only if it looks complete; anything else keeps the draft.
    private static func check(
        draft: String, material: String, format: ProgressNoteFormat, service: AssistantService,
        builder: DigestBuilder, live: @escaping DigestBuilder.Live, accept: (String) -> Void
    ) async -> CheckOutcome {
        let prompt = Prompts.noteCheck(draft: draft, material: material)
        guard service.fits(prompt: prompt) else { return .tooLong }
        do {
            let corrected = try await builder.runStage(
                prompt, read: "Checking", write: "Writing corrections", task: .note, service: service, live: live)
            guard plausiblyComplete(corrected, draft: draft, format: format) else { return .incomplete }
            accept(corrected)
            return .ran
        } catch is CancellationError {
            return .stopped
        } catch {
            return .failed
        }
    }

    /// A corrected note is taken only if it is at least 60% as long as the draft
    /// and keeps every section heading the draft had.
    static func plausiblyComplete(_ corrected: String, draft: String, format: ProgressNoteFormat) -> Bool {
        guard corrected.count * 10 >= draft.count * 6 else { return false }
        return format.sections.map(\.heading).allSatisfy { heading in
            !draft.localizedCaseInsensitiveContains(heading) || corrected.localizedCaseInsensitiveContains(heading)
        }
    }

    /// The stored digest if current, else one built now. A background build for
    /// the same session is cancelled first so the two don't both run.
    private static func currentDigest(
        transcript: String, service: AssistantService, builder: DigestBuilder, sessionID: UUID,
        load: () async -> SessionDigest?, save: (SessionDigest) throws -> Void, live: @escaping DigestBuilder.Live
    ) async throws -> SessionDigest {
        if let stored = await load() { return stored }
        let built = try await builder.buildInline(
            sessionID: sessionID, transcript: transcript, service: service,
            live: { started, change in
                live(started) {
                    change(&$0)
                    if !$0.readTitle.hasPrefix("Building digest") { $0.readTitle = "Building digest · \($0.readTitle)" }
                }
            })
        // Failing to keep the digest must not fail the note.
        try? save(built)
        return built
    }

    private final class StatsBox: @unchecked Sendable {
        var value: AIRunStats?
    }

    /// `text` cut at a line break to fit `limit` characters, and whether it was cut.
    static func fit(_ text: String, to limit: Int) -> (text: String, shortened: Bool) {
        guard text.count > limit else { return (text, false) }
        guard limit > 40 else { return ("", true) }
        let cut = text.prefix(limit - 20)
        let whole = cut.lastIndex(of: "\n").map { String(cut[..<$0]) } ?? String(cut)
        return (whole + "\n[digest shortened]", true)
    }

    nonisolated static func nonBlankLines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Passages

    /// Lines that mention risk, most specific first: explicit statements (ending
    /// it, wanting to die, hurting someone), then single words that can mean
    /// risk (pills, gun, worthless), then weaker context (plan, alcohol). Lines
    /// are matched on their own words, not through the search index, so
    /// paraphrases like "I don't want to be here anymore" are found.
    private nonisolated static let riskPatterns = [
        #"\b(suicid\w*|homicid\w*|kill(ing)? (my ?self|him ?self|her ?self|them ?selves|someone|somebody|you|him|her|them)|(hurt|hurting|harm|harming) (my ?self|someone|somebody|others|him|her|them)|(end|ending|ended) (it|my life|things|everything)|take my (own )?life|(want|wanted|wish)\w* (to )?(die|be dead|disappear)|wish i (was|were) (dead|gone)|better off without me|(not|n't) (want|wanna) (to )?(be here|go on|live)|be here any ?more|no (reason|point) (to|in) (live|living)|(thinking|thought|thoughts) (of|about) (dying|death|ending))\b"#,
        #"\b(die|dying|died|dead|death|overdos\w*|pills|gun|guns|weapon\w*|knife|cut(ting)?|cuts|worthless|hopeless|burden|abus\w*|unsafe|self.?harm|(?-i:OD))\b"#,
        #"\b(plan|intent|intend\w*|safe|safety|drink\w*|drunk|alcohol|drugs?|high)\b"#,
    ]

    /// Search queries, one set of words per kind of content a note section needs
    /// (risk is handled separately, and first).
    private nonisolated static let feelingWords = "feel feeling felt mood anxious anxiety sad angry worried sleep stress tired"
    private nonisolated static let interventionWords = "try exercise breathe practice technique skill notice reframe thought"
    private nonisolated static let planWords = "homework plan next appointment follow schedule medication"

    /// The queries for `format`'s sections (all of them for the template-free summary).
    nonisolated static func topics(for format: ProgressNoteFormat) -> [String] {
        var out: [String] = []
        func add(_ words: String) { if !out.contains(words) { out.append(words) } }
        let headings = format.sections.map(\.heading)
        if headings.isEmpty { [feelingWords, interventionWords, planWords].forEach(add) }
        for heading in headings {
            switch heading {
            case "Intervention": add(interventionWords)
            case "Plan": add(planWords)
            default: add(feelingWords)
            }
        }
        return out
    }

    /// Passages of `transcript` up to `limit` characters: risk lines first (their
    /// own `riskLimit`), then each note topic's best matches, the topics taking
    /// turns. Each hit brings its neighbouring lines; the result is in transcript
    /// order with `[…]` between gaps, and `lineCount` counts the non-blank lines
    /// it holds. Topic search is the app's own `SessionSearch`.
    nonisolated static func passages(
        in transcript: String, format: ProgressNoteFormat, limit: Int, riskLimit: Int
    ) -> (text: String, lineCount: Int) {
        guard limit > 0 else { return ("", 0) }
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var chosen: [Int: String] = [:]
        var used = 0
        /// Adds `candidates` (line index, text) not yet chosen, if they fit under `cap`.
        @discardableResult
        func take(_ candidates: [(line: Int, text: String)], cap: Int) -> Bool {
            let fresh = candidates.filter {
                chosen[$0.line] == nil && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
            }
            let cost = fresh.reduce(0) { $0 + $1.text.count + 1 }
            guard used + cost <= cap else { return false }
            for item in fresh { chosen[item.line] = item.text }
            used += cost
            return true
        }

        // Risk first, most specific tier first, within its own room.
        let regexes = riskPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        var flagged: [(tier: Int, line: Int)] = []
        for (index, text) in lines.enumerated() {
            let range = NSRange(text.startIndex..., in: text)
            if let tier = regexes.firstIndex(where: { $0.firstMatch(in: text, range: range) != nil }) {
                flagged.append((tier, index))
            }
        }
        for item in flagged.sorted(by: { ($0.tier, $0.line) < ($1.tier, $1.line) }) where used < min(riskLimit, limit) {
            let around = max(0, item.line - 1)...min(lines.count - 1, item.line + 1)
            let cap = min(riskLimit, limit)
            // Neighbouring lines if they fit, else the flagged line alone.
            if !take(around.map { ($0, lines[$0]) }, cap: cap) { take([(item.line, lines[item.line])], cap: cap) }
        }

        // Then the note's own topics, taking turns, until the room is used.
        let document = SessionSearch.Document(date: Date(), tag: "S1", kind: .transcript, text: transcript)
        let hits = topics(for: format).map { SessionSearch.search([document], question: $0).hits }
        var next = Array(repeating: 0, count: hits.count)
        while used < limit, hits.indices.contains(where: { next[$0] < hits[$0].count }) {
            for topic in hits.indices where next[topic] < hits[topic].count {
                let hit = hits[topic][next[topic]]
                next[topic] += 1
                take(hit.context.enumerated().map { (hit.contextStart + $0.offset, $0.element) }, cap: limit)
            }
        }

        var out: [String] = []
        var previous: Int?
        for index in chosen.keys.sorted() {
            if let previous, index != previous + 1 { out.append("[…]") }
            out.append(chosen[index] ?? "")
            previous = index
        }
        return (out.joined(separator: "\n"), chosen.count)
    }

    // MARK: - Coverage

    /// What the note was written from, as sent. `check` is nil when no check
    /// applies (not Focus).
    static func coverageLabel(
        digestParts: Int, digestShortened: Bool = false, passageLines: Int, totalLines: Int,
        effort: AnswerEffort, check: CheckOutcome?
    ) -> String {
        var text = "Read: a summary of the whole session (\(digestParts) parts"
            + (digestShortened ? ", shortened to fit" : "")
            + ") plus \(passageLines) of \(totalLines) transcript lines · \(effort.displayName). Details outside those lines may be missing."
        if let check { text += " " + check.text }
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
        session, then passages from the original transcript: lines about risk, then \
        lines chosen for each part of the note; […] marks skipped lines. Use the \
        digest for the overall picture. Take quotes, risk statements and denials only \
        from the passages. Do not add detail that neither contains.)

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
