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
    /// Maximum material room (digest + risk lines + top topic hits) used at Fast effort
    /// so the model reads a compact prompt quickly while still keeping risk lines.
    static let fastMaterialLimit = 8_000

    /// How the Focus check ended.
    enum CheckOutcome: Equatable {
        case ran, noRoom, tooLong, failed, incomplete, alteredRisk, stopped

        var text: String {
            switch self {
            case .ran: return "Checked against the passages."
            case .noRoom: return "Not checked: not enough room for the check."
            case .tooLong: return "Not checked: the draft was too long to check."
            case .failed: return "The check didn't run (it failed), so this is the unchecked draft."
            case .incomplete: return "The check's result looked incomplete, so this is the unchecked draft."
            case .alteredRisk: return "The check's correction changed a risk statement, so it was skipped and this is the unchecked draft."
            case .stopped: return "Stopped before the check finished; this is the unchecked draft."
            }
        }
    }

    /// Added to the coverage line when the user stopped while the note was being written.
    static let stoppedEarlyText = "Stopped early: this note is only what was written before you stopped."

    // MARK: - Run

    static func stream(
        format: ProgressNoteFormat,
        transcript: String,
        notes: String = "",
        comments: [SessionComment] = [],
        patientBackground: String = "",
        verbosity: SummaryVerbosity = .default,
        instructions: String? = nil,
        effort: AnswerEffort = .default,
        riskPhrases: [String],
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
                patientBackground: patientBackground,
                verbosity: verbosity, instructions: instructions)
        }
        if service.fits(prompt: prompt(transcript)) {
            return service.streamProgressNote(
                format: format, transcript: transcript, notes: notes, comments: comments,
                patientBackground: patientBackground,
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
                    let transcriptCopy = transcript
                    let flaggedCost = await offMain { strongCost(in: transcriptCopy, phrases: riskPhrases) }
                    try Task.checkCancellation()
                    var room = total
                    var plannedCheck: CheckOutcome?
                    if effort == .fast {
                        room = min(total, max(fastMaterialLimit, flaggedCost + digestShare))
                    } else if effort == .focus {
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
                    let strongBudget = min(flaggedCost, room * 2 / 3)
                    let (digestText, cut) = fit(
                        Prompts.longSessionDigest(digest.sessionDigest), to: room - strongBudget - riskLimit)
                    let omitted = cut && digestText.isEmpty
                    let shortened = cut && !omitted
                    let limit = room - digestText.count
                    let found = await offMain {
                        passages(
                            in: transcriptCopy, format: format, limit: limit, riskLimit: riskLimit,
                            phrases: riskPhrases, strongBudget: strongBudget)
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
                        grammar: format.grammar,
                        service: drafter, live: live, onSnapshot: { continuation.yield($0) })
                    try Task.checkCancellation()

                    if effort == .focus, plannedCheck == nil, !draft.isEmpty {
                        let outcome = await check(
                            draft: draft, material: material, format: format, phrases: riskPhrases, service: service,
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
        draft: String, material: String, format: ProgressNoteFormat, phrases: [String],
        service: AssistantService, builder: DigestBuilder, live: @escaping DigestBuilder.Live, accept: (String) -> Void
    ) async -> CheckOutcome {
        let prompt = Prompts.noteCheck(draft: draft, material: material)
        guard service.fits(prompt: prompt) else { return .tooLong }
        do {
            let corrected = try await builder.runStage(
                prompt, read: "Checking", write: "Writing corrections", task: .note,
                grammar: format.grammar, service: service, live: live)
            if let why = rejection(corrected, draft: draft, format: format, phrases: phrases) { return why }
            accept(corrected)
            return .ran
        } catch is CancellationError {
            return .stopped
        } catch let error as URLError where error.code == .cancelled {
            return .stopped
        } catch {
            return .failed
        }
    }

    /// A corrected note is taken only if it is at least 60% as long as the draft,
    /// keeps every section heading line, and leaves risk statements alone: every
    /// draft sentence with a risk phrase must be in the correction word
    /// for word, in the same section, and the correction may add no such
    /// sentence of its own (so no flipped, dropped, moved or invented denial).
    nonisolated static func plausiblyComplete(
        _ corrected: String, draft: String, format: ProgressNoteFormat, phrases: [String]
    ) -> Bool {
        rejection(corrected, draft: draft, format: format, phrases: phrases) == nil
    }

    /// Why a corrected note is not taken, or nil if it is.
    nonisolated static func rejection(
        _ corrected: String, draft: String, format: ProgressNoteFormat, phrases: [String]
    ) -> CheckOutcome? {
        guard corrected.count * 10 >= draft.count * 6 else { return .incomplete }
        guard headingLines(draft, format).isSubset(of: headingLines(corrected, format)) else { return .incomplete }
        let matcher = RiskPhraseMatcher(phrases)
        let before = Set(sentences(draft, format, matcher: nil))
        let after = Set(sentences(corrected, format, matcher: nil))
        if sentences(draft, format, matcher: matcher).contains(where: { !after.contains($0) }) { return .alteredRisk }
        if sentences(corrected, format, matcher: matcher).contains(where: { !before.contains($0) }) { return .alteredRisk }
        return nil
    }

    /// Which of the format's headings stand on a line of their own in `text`.
    private nonisolated static func headingLines(_ text: String, _ format: ProgressNoteFormat) -> Set<String> {
        let wanted = Set(format.sections.map { $0.heading.lowercased() })
        let marks = CharacterSet(charactersIn: "#*_: \t")
        return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: marks).lowercased() }.filter(wanted.contains))
    }

    /// The sentences of `text`, each tagged with the section it is in and
    /// whitespace-normalised; only those with a risk phrase if a `matcher` is given.
    private nonisolated static func sentences(_ text: String, _ format: ProgressNoteFormat, matcher: RiskPhraseMatcher?) -> [String] {
        let wanted = Set(format.sections.map { $0.heading.lowercased() })
        let marks = CharacterSet(charactersIn: "#*_: \t")
        var section = ""
        var out: [String] = []
        func add(_ piece: String) {
            var straight = piece
            for mark in ["\u{2018}", "\u{2019}", "\u{02BC}"] { straight = straight.replacingOccurrences(of: mark, with: "'") }
            let squashed = straight
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*\u{2022} .!?"))
            guard !squashed.isEmpty else { return }
            if let matcher, matcher.firstMatch(in: squashed) == nil { return }
            out.append(section + "\u{1}" + squashed)
        }
        for line in text.split(separator: "\n") {
            if wanted.contains(line.trimmingCharacters(in: marks).lowercased()) {
                section = line.trimmingCharacters(in: marks).lowercased()
                continue
            }
            let chars = Array(line)
            var start = 0
            for (index, char) in chars.enumerated() where ".!?".contains(char) && (index + 1 == chars.count || chars[index + 1].isWhitespace) {
                add(String(chars[start...index]))
                start = index + 1
            }
            if start < chars.count { add(String(chars[start...])) }
        }
        return out
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

    /// The phrases a new install starts with: suicide, self-harm and violence,
    /// worded so they don't turn up in ordinary talk. The user can edit the list
    /// in Settings (add, remove, clear, reset to this). Matching is case-insensitive
    /// and whole-word; ' and ’ are the same character.
    nonisolated static let defaultRiskPhrases: [String] = [
        // Suicide: statements
        "suicide", "suicidal", "kill myself", "killing myself", "end my life", "end my own life",
        "ending my life", "take my life", "take my own life", "end it all", "ending it all",
        "want to die", "wanna die", "wish I was dead", "wish I were dead", "better off dead",
        "better off without me", "rather be dead",
        // Suicide: passive
        "don't want to be here anymore", "don't want to live", "don't want to wake up",
        "hope I don't wake up", "never wake up", "nothing to live for", "no reason to live",
        "thoughts of dying", "can't go on",
        // Suicide: plans and means
        "plan to kill", "overdose", "overdosed", "took all my pills", "took a whole bottle",
        "hang myself", "walk into traffic", "jump off",
        // Suicide: clinical shorthand
        "denies SI", "endorses SI", "history of SI", "SI/HI", "denies HI", "endorses HI",
        // Self-harm
        "cut myself", "cutting myself", "I've been cutting myself", "burn myself", "burning myself",
        "hurt myself", "hurting myself", "harm myself", "harming myself", "self-harm",
        "self harm", "hit myself", "starving myself", "denies SH", "endorses SH",
        // Violence to others and by others
        "kill him", "kill her", "kill them", "kill you", "kill someone", "kill people",
        "gonna kill", "going to kill", "threatened to kill", "killed himself", "killed herself",
        "killing himself", "killing herself", "murder him", "murder her", "murder them",
        "homicidal", "homicide", "want to hurt him", "want to hurt her", "want to hurt someone",
        "want to hurt myself", "hurt someone", "harm others", "shoot up the", "shoot him",
        "shoot her", "stab him", "stab her", "stab myself", "he hit me", "she hit me",
        "hits me when", "beat me up", "choked me",
    ]

    /// Each line that holds a risk phrase, with where the first one sits.
    private nonisolated static func flaggedLines(
        _ lines: [String], matcher: RiskPhraseMatcher
    ) -> [(line: Int, match: NSRange)] {
        var flagged: [(line: Int, match: NSRange)] = []
        for (index, text) in lines.enumerated() {
            if Task.isCancelled { return [] }
            if let match = matcher.firstMatch(in: text) { flagged.append((index, match)) }
        }
        return flagged
    }

    /// Characters the risk-phrase lines take on their own.
    nonisolated static func strongCost(in transcript: String, phrases: [String]) -> Int {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return flaggedLines(lines, matcher: RiskPhraseMatcher(phrases)).reduce(0) { $0 + lines[$1.line].count + 1 }
    }

    /// `text` cut to about `width` characters around `match`, with a marker at each cut end.
    nonisolated static func window(_ text: String, around match: NSRange, width: Int) -> String {
        let marker = "[…truncated]"
        guard let found = Range(match, in: text) else { return String(text.prefix(width)) + " " + marker }
        let start = text.distance(from: text.startIndex, to: found.lowerBound)
        let length = text.distance(from: found.lowerBound, to: found.upperBound)
        let total = text.count
        var low = start
        var high = min(total, start + width)
        if length < width {
            low = max(0, start - (width - length) / 2)
            high = min(total, low + width)
            low = max(0, high - width)
        }
        let body = String(text.dropFirst(low).prefix(high - low))
        return (low > 0 ? marker + " " : "") + body + (high < total ? " " + marker : "")
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
    /// every line with one of `phrases` (spread over the session if they don't
    /// all fit; one too long for the room is cut around its phrase, with a
    /// marker), then the neighbours of those that fit, from `riskLimit` only. Then each note topic's
    /// best matches, the topics taking turns; each hit brings its neighbouring
    /// lines. The result is in transcript order with `[…]` between gaps;
    /// `lineCount` counts the non-blank lines it holds and `droppedRisk` the
    /// risk lines that did not fit or were cut short. Topic search is the app's own
    /// `SessionSearch`. Stops early (returning nothing) if its task is cancelled.
    nonisolated static func passages(
        in transcript: String, format: ProgressNoteFormat, limit: Int, riskLimit: Int,
        phrases: [String], strongBudget: Int = 0
    ) -> (text: String, lineCount: Int, droppedRisk: Int) {
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

        let flagged = flaggedLines(lines, matcher: RiskPhraseMatcher(phrases))
        let matches = Dictionary(flagged.map { ($0.line, $0.match) }, uniquingKeysWith: { first, _ in first })
        let strong = spread(flagged.map(\.line))
        guard limit > 0 else { return ("", 0, strong.count) }
        // Each risk line on its own, before anything else: up to what `stream` set
        // aside for them (`strongBudget`) or two thirds of the room, whichever is
        // more, and never past the room itself.
        let strongCap = min(limit, max(limit * 2 / 3, strongBudget))
        var shortened = 0
        for line in strong where chosen[line] == nil {
            let room = strongCap - used
            if lines[line].count + 1 <= room {
                take([(line, lines[line])], cap: strongCap)
            } else if room >= 60, let match = matches[line] {
                // Keep the part that holds the phrase.
                let cut = window(lines[line], around: match, width: room - 30)
                chosen[line] = cut
                used += cut.count + 1
                shortened += 1
            }
        }
        // Neighbours of the lines that made it in, from their own allowance.
        var extras = 0
        func extra(_ line: Int) {
            let before = used
            take([(line, lines[line])], cap: min(limit, before + riskLimit - extras))
            extras += used - before
        }
        for line in strong where chosen[line] != nil {
            if Task.isCancelled { return ("", 0, 0) }
            if line > 0 { extra(line - 1) }
            if line + 1 < lines.count { extra(line + 1) }
        }

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
        return (out.joined(separator: "\n"), chosen.count, strong.filter { chosen[$0] == nil }.count + shortened)
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
            text += " \(droppedRisk) risk-flagged line\(droppedRisk == 1 ? "" : "s") didn't fit or were shortened; check the transcript for risk."
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


/// Finds lines holding any of a list of plain phrases: case-insensitive, whole
/// word, any run of spaces for a space, and ' ‘ ’ ʼ all the same character.
/// Phrases are escaped, so no pattern syntax reaches the regex engine.
struct RiskPhraseMatcher {
    private static let apostrophes: [Character] = ["'", "\u{2018}", "\u{2019}", "\u{02BC}"]

    private let regex: NSRegularExpression?
    /// Used only if the pattern ever fails to compile: case-insensitive
    /// substring matching on the phrases themselves, so a failure never means no matches.
    private let literals: [String]

    init(_ phrases: [String], forceLiteralFallback: Bool = false) {
        let apostrophe = #"['‘’ʼ]"#
        let parts = phrases.compactMap { raw -> String? in
            let words = raw.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { return nil }
            return words.map { word in
                word.map { Self.apostrophes.contains($0) ? apostrophe : NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined()
            }.joined(separator: #"\s+"#)
        }
        literals = phrases.map { Self.straight($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.isEmpty }
        guard !parts.isEmpty, !forceLiteralFallback else {
            regex = nil
            return
        }
        let compiled = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])(?:"# + parts.joined(separator: "|") + #")(?![\p{L}\p{N}])"#,
            options: [.caseInsensitive])
        if compiled == nil { assertionFailure("risk phrase pattern failed to compile") }
        regex = compiled
    }

    /// Where the first phrase sits in `text`, if any does.
    func firstMatch(in text: String) -> NSRange? {
        if let regex { return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.range }
        // Every apostrophe form is one UTF-16 unit, so ranges in `plain` hold for `text`.
        let plain = Self.straight(text)
        for literal in literals {
            if let found = plain.range(of: literal, options: .caseInsensitive) { return NSRange(found, in: plain) }
        }
        return nil
    }

    /// `text` with every apostrophe form as a straight one.
    private static func straight(_ text: String) -> String {
        String(text.map { apostrophes.contains($0) ? "'" : $0 })
    }

    /// A phrase as the matcher sees it: apostrophes alike, spaces collapsed, no case.
    static func normalized(_ phrase: String) -> String {
        straight(phrase).split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
