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
                    // Risk lines get their room first (every flagged line, then neighbours from
                    // `riskLimit`); the digest shrinks, or goes, to fit what is left.
                    let riskLimit = min(riskReserve, room / 3)
                    let transcriptCopy = transcript
                    let flaggedCost = await offMain { riskCost(in: transcriptCopy) }
                    try Task.checkCancellation()
                    let (digestText, cut) = fit(
                        Prompts.longSessionDigest(digest.sessionDigest), to: room - min(flaggedCost, room * 2 / 3) - riskLimit)
                    let omitted = cut && digestText.isEmpty
                    let shortened = cut && !omitted
                    let limit = room - digestText.count
                    let found = await offMain {
                        passages(in: transcriptCopy, format: format, limit: limit, riskLimit: riskLimit)
                    }
                    try Task.checkCancellation()
                    let material = Prompts.longSessionMaterial(digest: digestText, passages: found.text)
                    let totalLines = nonBlankLines(transcript).count
                    @MainActor func label(_ check: CheckOutcome?) -> String {
                        coverageLabel(
                            digestParts: digest.sections.count, digestShortened: shortened, digestOmitted: omitted,
                            passageLines: found.lineCount, totalLines: totalLines, effort: effort,
                            droppedRisk: found.droppedRisk, check: check)
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

    /// A corrected note is taken only if it is at least 60% as long as the draft,
    /// keeps every section heading line the draft had, keeps every risk term the
    /// draft had (including "denies SI"), and adds no risk negation of its own.
    nonisolated static func plausiblyComplete(_ corrected: String, draft: String, format: ProgressNoteFormat) -> Bool {
        guard corrected.count * 10 >= draft.count * 6 else { return false }
        guard headingLines(draft, format).isSubset(of: headingLines(corrected, format)) else { return false }
        let after = riskTerms(corrected)
        for (term, count) in riskTerms(draft) where (after[term] ?? 0) < count { return false }
        return negatedRiskCount(corrected) <= negatedRiskCount(draft)
    }

    /// Which of the format's headings stand on a line of their own in `text`.
    private nonisolated static func headingLines(_ text: String, _ format: ProgressNoteFormat) -> Set<String> {
        let wanted = Set(format.sections.map { $0.heading.lowercased() })
        let marks = CharacterSet(charactersIn: "#*_: \t")
        return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: marks).lowercased() }.filter(wanted.contains))
    }

    /// Each strong risk phrase in `text` (tiers 1 and 2), lowercased, with how often it appears.
    private nonisolated static func riskTerms(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for regex in riskRegexes().prefix(2) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                counts[normalised(String(text[range])), default: 0] += 1
            }
        }
        return counts
    }

    private nonisolated static func negatedRiskCount(_ text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: negatedRiskPattern, options: [.caseInsensitive]) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private nonisolated static func normalised(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
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

    /// Runs `work` off the main actor; cancelling the caller cancels it too.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
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

    /// Lines that mention risk, most specific first: explicit statements and
    /// violence (ending it, not wanting to be here, hurting someone, being hit,
    /// SI/HI), then single words that can mean risk (pills, gun, worthless,
    /// stopping medication), then weaker context (plan, alcohol). Lines are
    /// matched on their own words, not through the search index, so paraphrases
    /// are found. Case-insensitive except SI/HI/SH/SA/OD. A negation like
    /// "don't" has no word boundary before "n't", so those alternatives carry
    /// their own anchors.
    private nonisolated static let riskPatterns = [
        #"\b(?:suicid\w*|homicid\w*|kill(?:ing|ed)? (?:my ?self|him ?self|her ?self|them ?selves|someone|somebody|you|him|her|them)|(?:hurt|harm|hit|beat|slap|kick)(?:s|ting|ing|ped)? (?:my ?self|someone|somebody|others|him|her|them|(?:my|our|the|his|her|their) (?:kids?|child(?:ren)?|baby|son|daughter|wife|husband|partner))|(?:hit|beat|slap|kick)(?:s|ting|ing|ped)? (?:me|my|up)|(?:end|ending|ended) (?:it|my life|things|everything)|take my (?:own )?life|(?:want|wanted|wish)\w* (?:to )?(?:die|be dead|disappear)|wish i (?:was|were) (?:dead|gone)|wish i (?:wouldn['\u2019]t|would not|didn['\u2019]t|did not) (?:wake|exist)|better off without me|be here any ?more|no (?:reason|point) (?:to|in) (?:live|living|go on|going on|keep going|keep living|continue)|(?:thinking|thought|thoughts) (?:of|about) (?:dying|death|ending)|jump(?:ing)? (?:off|from)|shoot(?:s|ing)?|stab(?:s|bing|bed)?|chok\w*|strangl\w*|punch\w*|rap(?:e|ed|es|ing)|molest\w*|assault\w*|threat\w*)\b|\b(?:can['\u2019]t|cannot|can not) (?:go on|do this any ?more|take (?:it|this) any ?more|keep going|keep doing this|carry on)|\b(?:scared|afraid|frightened|terrified) (?:to go home|of (?:him|her|them|my \w+))|(?-i:\b(?:SI|HI|SH|SA)\b)|(?:\bnot|n['\u2019]t) (?:want|wanna) (?:to )?(?:be here|go on|live|be alive|exist)|(?:\bnot|n['\u2019]t) see (?:the |any )?point|(?:\bnot|n['\u2019]t) worth (?:living|it all)"#,
        #"\b(?:die|dying|died|dead|death|overdos\w*|pills|gun|guns|weapon\w*|knife|cut(?:ting)?|cuts|worthless|hopeless|burden|abus\w*|unsafe|self.?harm|(?-i:OD)|(?:stopp?ed|stopping|quit|skipp?ed|skipping|missed|off) (?:taking )?(?:my |his |her |their |the )?(?:meds?|medications?|medicine|pills|antidepressants?|lithium|prescriptions?))\b"#,
        #"\b(?:plan|intent|intend\w*|safe|safety|drink\w*|drunk|alcohol|drugs?|high)\b"#,
    ]

    /// "Denies SI", "no suicidal ideation": a negated risk term.
    private nonisolated static let negatedRiskPattern =
        #"\b(?:denies|denied|denying|deny|no|nor|negative for|without|reports no|(?:did not|didn['\u2019]t|does not|doesn['\u2019]t) endorse)\s+(?:(?:any|current|active|thoughts of|history of)\s+)*(?:suicid\w*|homicid\w*|self.?harm|(?-i:SI|HI|SH|SA)\b)"#

    /// The risk patterns compiled, in tier order.
    nonisolated static func riskRegexes() -> [NSRegularExpression] {
        riskPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    /// Each line that matches a risk tier (the first, most specific, that does).
    private nonisolated static func flaggedLines(_ lines: [String]) -> [(tier: Int, line: Int)] {
        let regexes = riskRegexes()
        var flagged: [(tier: Int, line: Int)] = []
        for (index, text) in lines.enumerated() {
            if Task.isCancelled { return [] }
            let range = NSRange(text.startIndex..., in: text)
            if let tier = regexes.firstIndex(where: { $0.firstMatch(in: text, range: range) != nil }) {
                flagged.append((tier, index))
            }
        }
        return flagged
    }

    /// Characters the strong risk lines (tiers 1 and 2) take on their own.
    nonisolated static func riskCost(in transcript: String) -> Int {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return flaggedLines(lines).filter { $0.tier < 2 }.reduce(0) { $0 + lines[$1.line].count + 1 }
    }

    /// `items` reordered so any prefix is spread over the whole list: both ends
    /// first, then midpoints. Keeps early chatter from starving later lines.
    nonisolated static func spread<T>(_ items: [T]) -> [T] {
        guard items.count > 2 else { return items }
        var out = [items[0], items[items.count - 1]]
        var queue = [(lo: 1, hi: items.count - 1)]
        var next = 0
        while next < queue.count {
            let (lo, hi) = queue[next]
            next += 1
            guard lo < hi else { continue }
            let mid = (lo + hi) / 2
            out.append(items[mid])
            queue.append((lo, mid))
            queue.append((mid + 1, hi))
        }
        return out
    }

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

    /// Passages of `transcript` up to `limit` characters. Risk lines come first:
    /// every strong risk line (tiers 1 and 2, spread over the session if they
    /// don't all fit; one too long for the room is cut with a marker), then their
    /// neighbours and the weak tier, from `riskLimit` only. Then each note topic's
    /// best matches, the topics taking turns; each hit brings its neighbouring
    /// lines. The result is in transcript order with `[…]` between gaps;
    /// `lineCount` counts the non-blank lines it holds and `droppedRisk` the
    /// strong risk lines that did not fit. Topic search is the app's own
    /// `SessionSearch`. Stops early (returning nothing) if its task is cancelled.
    nonisolated static func passages(
        in transcript: String, format: ProgressNoteFormat, limit: Int, riskLimit: Int
    ) -> (text: String, lineCount: Int, droppedRisk: Int) {
        guard limit > 0 else { return ("", 0, 0) }
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

        let flagged = flaggedLines(lines)
        let strong = (0...1).flatMap { tier in spread(flagged.filter { $0.tier == tier }.map(\.line)) }
        let weak = spread(flagged.filter { $0.tier >= 2 }.map(\.line))
        // Each strong risk line on its own, before anything else.
        for line in strong where chosen[line] == nil {
            let room = limit - used
            if lines[line].count + 1 <= room {
                take([(line, lines[line])], cap: limit)
            } else if room >= 60 {
                chosen[line] = String(lines[line].prefix(room - 16)) + " […truncated]"
                used = limit
            }
        }
        // Neighbours and weak-tier lines, from their own allowance.
        var extras = 0
        func extra(_ line: Int) {
            let before = used
            take([(line, lines[line])], cap: min(limit, before + riskLimit - extras))
            extras += used - before
        }
        for line in strong {
            if Task.isCancelled { return ("", 0, 0) }
            if line > 0 { extra(line - 1) }
            if line + 1 < lines.count { extra(line + 1) }
        }
        weak.forEach(extra)

        // Then the note's own topics, taking turns, until the room is used.
        let document = SessionSearch.Document(date: Date(), tag: "S1", kind: .transcript, text: transcript)
        var hits: [[SessionSearch.Hit]] = []
        for topic in topics(for: format) {
            if Task.isCancelled { break }
            hits.append(SessionSearch.search([document], question: topic).hits)
        }
        var next = Array(repeating: 0, count: hits.count)
        while used < limit, !Task.isCancelled, hits.indices.contains(where: { next[$0] < hits[$0].count }) {
            for topic in hits.indices where next[topic] < hits[topic].count {
                let hit = hits[topic][next[topic]]
                next[topic] += 1
                take(hit.context.enumerated().map { (hit.contextStart + $0.offset, $0.element) }, cap: limit)
            }
        }
        if Task.isCancelled { return ("", 0, 0) }

        var out: [String] = []
        var previous: Int?
        for index in chosen.keys.sorted() {
            if let previous, index != previous + 1 { out.append("[…]") }
            out.append(chosen[index] ?? "")
            previous = index
        }
        return (out.joined(separator: "\n"), chosen.count, strong.filter { chosen[$0] == nil }.count)
    }

    // MARK: - Coverage

    /// What the note was written from, as sent. `check` is nil when no check
    /// applies (not Focus).
    static func coverageLabel(
        digestParts: Int, digestShortened: Bool = false, digestOmitted: Bool = false, passageLines: Int,
        totalLines: Int, effort: AnswerEffort, droppedRisk: Int = 0, check: CheckOutcome?
    ) -> String {
        let summary = digestOmitted
            ? "no summary of the whole session (it didn't fit)"
            : "a summary of the whole session (\(digestParts) part\(digestParts == 1 ? "" : "s")"
                + (digestShortened ? ", shortened to fit" : "") + ")"
        var text = "Read: \(summary) plus \(passageLines) of \(totalLines) transcript lines · \(effort.displayName). "
            + "Details outside those lines may be missing."
        if droppedRisk > 0 {
            text += " \(droppedRisk) risk-flagged line\(droppedRisk == 1 ? "" : "s") didn't fit; check the transcript for risk."
        }
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
