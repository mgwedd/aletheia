import Foundation

// MARK: - Month-Merged Patient Digests (#286 Step 5)

/// Groups and budgets stored session digests across a patient's history.
/// Recent sessions keep their own digest under their session header; older
/// sessions beyond `recentIndividualLimit` are merged by calendar month so a
/// multi-year history stays covered and citable within the context budget.
enum PatientDigestMerger {
    /// How many of the newest sessions with digests stay under their individual
    /// session headers before older ones are grouped by calendar month.
    static let defaultRecentIndividualLimit = 6

    struct DatedDigest: Equatable {
        let tag: String
        let date: Date
        let folderName: String
        let digest: String
    }

    struct MonthBlock: Equatable {
        let monthTitle: String
        let tags: [String]
        let sources: [CitationSource]
        let text: String
    }

    struct Plan: Equatable {
        /// Keyed by session date for recent sessions whose digest goes under their own header.
        let individualByDate: [Date: String]
        /// Chronological (newest month first) merged blocks for older sessions.
        let monthBlocks: [MonthBlock]
        /// Total sessions whose digest was included (individually or in a month block).
        let digestSessionCount: Int
        /// Subset of `digestSessionCount` that were merged into month blocks.
        let monthMergedSessionCount: Int
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateStyle = .medium
        return f
    }()

    /// Budgets `digests` (ordered newest-first) into recent per-session blocks
    /// and older month-merged blocks, never exceeding `characterBudget`.
    static func plan(
        digests: [DatedDigest],
        recentIndividualLimit: Int = defaultRecentIndividualLimit,
        characterBudget: Int
    ) -> Plan {
        guard !digests.isEmpty, characterBudget > 80 else {
            return Plan(individualByDate: [:], monthBlocks: [], digestSessionCount: 0, monthMergedSessionCount: 0)
        }
        let ordered = digests.sorted { $0.date > $1.date }
        let recentSlice = Array(ordered.prefix(max(0, recentIndividualLimit)))
        let olderSlice = Array(ordered.dropFirst(max(0, recentIndividualLimit)))

        var remaining = characterBudget
        var individualByDate: [Date: String] = [:]
        var digestCount = 0

        // Reserve up to half of the digest budget for older month-merged history when older sessions exist.
        let recentCap = olderSlice.isEmpty ? characterBudget : max(characterBudget / 2, characterBudget - olderSlice.count * 450)
        var recentUsed = 0

        for item in recentSlice {
            let trimmed = item.digest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let prefix = "Session digest:\n"
            let available = min(remaining, recentCap - recentUsed) - prefix.count - 2
            guard available > 60 else { break }
            let body = fitDigest(trimmed, limit: available)
            let block = prefix + body
            individualByDate[item.date] = individualByDate[item.date].map { $0 + "\n\n" + block } ?? block
            let cost = block.count + 2
            remaining -= cost
            recentUsed += cost
            digestCount += 1
        }

        guard !olderSlice.isEmpty, remaining > 120 else {
            return Plan(
                individualByDate: individualByDate,
                monthBlocks: [],
                digestSessionCount: digestCount,
                monthMergedSessionCount: 0
            )
        }

        // Group older sessions by (year, month), newest month first.
        let calendar = Calendar(identifier: .gregorian)
        struct MonthKey: Hashable, Comparable {
            let year: Int
            let month: Int
            static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
                lhs.year != rhs.year ? lhs.year < rhs.year : lhs.month < rhs.month
            }
        }
        var grouped: [MonthKey: [DatedDigest]] = [:]
        for item in olderSlice {
            let comps = calendar.dateComponents([.year, .month], from: item.date)
            let key = MonthKey(year: comps.year ?? 0, month: comps.month ?? 0)
            grouped[key, default: []].append(item)
        }

        let sortedKeys = grouped.keys.sorted(by: >)
        var monthBlocks: [MonthBlock] = []
        var monthMergedCount = 0

        for (idx, key) in sortedKeys.enumerated() {
            guard let items = grouped[key], let firstDate = items.first?.date else { continue }
            let monthsLeft = max(1, sortedKeys.count - idx)
            let monthAllowance = max(min(remaining, 1_800), remaining / monthsLeft)
            let title = monthFormatter.string(from: firstDate)
            let tags = items.map(\.tag)
            let header = "===== Earlier Sessions: \(title) [\(tags.joined(separator: ", "))] ====="
            guard monthAllowance > header.count + 60 else { break }

            let perSessionLimit = max(80, (monthAllowance - header.count - 4) / max(1, items.count))
            var lines: [String] = []
            var includedTags: [String] = []
            var includedSources: [CitationSource] = []
            var usedInMonth = header.count + 1

            for item in items {
                let dateStr = shortDateFormatter.string(from: item.date)
                let lead = "[\(item.tag)] \(dateStr): "
                let roomForItem = min(perSessionLimit, remaining - usedInMonth) - lead.count - 1
                guard roomForItem > 40 else { break }
                let compact = item.digest
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let body = fitDigest(compact, limit: roomForItem)
                let entry = lead + body
                lines.append(entry)
                includedTags.append(item.tag)
                includedSources.append(CitationSource(tag: item.tag, date: item.date, folderName: item.folderName))
                usedInMonth += entry.count + 1
            }

            guard !lines.isEmpty else { break }
            let finalHeader = "===== Earlier Sessions: \(title) [\(includedTags.joined(separator: ", "))] ====="
            let blockText = finalHeader + "\n" + lines.joined(separator: "\n")
            monthBlocks.append(MonthBlock(
                monthTitle: title,
                tags: includedTags,
                sources: includedSources,
                text: blockText
            ))
            remaining -= (blockText.count + 2)
            digestCount += includedSources.count
            monthMergedCount += includedSources.count
            if remaining <= 100 { break }
        }

        return Plan(
            individualByDate: individualByDate,
            monthBlocks: monthBlocks,
            digestSessionCount: digestCount,
            monthMergedSessionCount: monthMergedCount
        )
    }

    private static func fitDigest(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 24 else { return String(text.prefix(max(0, limit))) }
        return String(text.prefix(limit - 18)) + "… [digest cut]"
    }
}

// MARK: - Local Read-Only Tools (#286 Step 3b)

/// A single read-only tool call requested by the model during second-pass refinement.
struct LocalToolCall: Equatable, Codable {
    var tool: String
    var query: String?
    var session: String?
    var start: String?
    var end: String?
    var from: String?
    var to: String?
}

/// The outcome of running one `LocalToolCall` against local session data.
struct LocalToolOutcome: Equatable {
    let call: LocalToolCall
    /// True when the tool name or arguments were invalid; `output` still goes back to the model.
    let isError: Bool
    /// Human-readable progress stage (e.g. `Searched "Dana" · 2 hits in 1 session`), nil on error.
    let stageTitle: String?
    /// Text returned to the model for this call.
    let output: String
    /// Session tags whose transcript passages were read by this call.
    let readTranscriptTags: Set<String>
    /// Session tags whose digests were read by this call.
    let readDigestTags: Set<String>
}

/// Read-only view of one session exposed to `LocalToolScope`. Never writes or touches the network.
struct LocalToolSession {
    let id: UUID
    let tag: String
    let date: Date
    let folderName: String
    let transcript: String
    let digest: SessionDigest?
    let notes: String
    let comments: [String]
}

/// Executes read-only local tool calls (`search`, `read_section`, `get_digest`, `list_sessions`)
/// scoped strictly to the current patient (or single session).
struct LocalToolScope {
    let sessions: [LocalToolSession]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateStyle = .medium
        return f
    }()

    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Validates and executes `call` against `sessions`, capping the returned text to `maxCharacters`.
    func execute(_ call: LocalToolCall, maxCharacters: Int = 2_400) -> LocalToolOutcome {
        let name = call.tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "search":
            return executeSearch(call, maxCharacters: maxCharacters)
        case "read_section":
            return executeReadSection(call, maxCharacters: maxCharacters)
        case "get_digest":
            return executeGetDigest(call, maxCharacters: maxCharacters)
        case "list_sessions":
            return executeListSessions(call, maxCharacters: maxCharacters)
        default:
            return errorOutcome(
                call,
                "Error: unknown tool \"\(call.tool)\". Available tools are search, read_section, get_digest, list_sessions."
            )
        }
    }

    // MARK: Tool implementations

    private func executeSearch(_ call: LocalToolCall, maxCharacters: Int) -> LocalToolOutcome {
        let query = (call.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return errorOutcome(call, "Error: search requires a non-empty \"query\" argument.")
        }
        let rangeResult = parseDateBounds(from: call.from, to: call.to)
        if case .failure(let message) = rangeResult {
            return errorOutcome(call, message)
        }
        let bounds = (try? rangeResult.get()) ?? nil

        let filtered = sessions.filter { session in
            if let from = bounds?.from, session.date < from { return false }
            if let to = bounds?.to, session.date > to { return false }
            return true
        }
        var docs: [SessionSearch.Document] = []
        for s in filtered {
            if !s.transcript.isEmpty {
                docs.append(.init(date: s.date, tag: s.tag, kind: .transcript, text: s.transcript, session: s.id))
            }
            if !s.notes.isEmpty {
                docs.append(.init(date: s.date, tag: s.tag, kind: .sessionNotes, text: s.notes, session: s.id))
            }
            for comment in s.comments where !comment.isEmpty {
                docs.append(.init(date: s.date, tag: s.tag, kind: .comment, text: comment, session: s.id))
            }
        }
        let result = SessionSearch.search(docs, question: query, characterBudget: maxCharacters)
        let totalHits = result.totalMentions
        let sessionHits = result.sessionsWithHits
        let stage = "Searched \"\(query)\" · \(totalHits) hit\(totalHits == 1 ? "" : "s") in \(sessionHits) session\(sessionHits == 1 ? "" : "s")"

        guard !result.hits.isEmpty else {
            return LocalToolOutcome(
                call: call,
                isError: false,
                stageTitle: stage,
                output: "Search for \"\(query)\": 0 matches across \(filtered.count) session\(filtered.count == 1 ? "" : "s").",
                readTranscriptTags: [],
                readDigestTags: []
            )
        }

        var lines: [String] = [
            "Search for \"\(query)\": \(totalHits) match\(totalHits == 1 ? "" : "es") in \(sessionHits) of \(filtered.count) session\(filtered.count == 1 ? "" : "s")."
        ]
        var used = lines[0].count
        var readTags = Set<String>()
        for hit in result.hits.prefix(6) {
            // Only transcript hits carry context lines; a notes or comment hit is its paragraph.
            let passage = hit.kind == .transcript
                ? hit.context.joined(separator: "\n")
                : Self.paragraph(in: docs[hit.documentIndex].text, from: hit.lineIndex)
            let snippet = TranscriptCompactor.compact(passage)
            let entry = "[\(hit.tag)] (\(Self.dateFormatter.string(from: hit.date))):\n\(snippet)"
            if used + entry.count + 2 > maxCharacters {
                let left = maxCharacters - used - 20
                if left > 60 {
                    lines.append(String(entry.prefix(left)) + "…")
                    if hit.kind == .transcript { readTags.insert(hit.tag) }
                }
                break
            }
            lines.append(entry)
            used += entry.count + 2
            if hit.kind == .transcript { readTags.insert(hit.tag) }
        }
        return LocalToolOutcome(
            call: call,
            isError: false,
            stageTitle: stage,
            output: lines.joined(separator: "\n"),
            readTranscriptTags: readTags,
            readDigestTags: []
        )
    }

    private func executeReadSection(_ call: LocalToolCall, maxCharacters: Int) -> LocalToolOutcome {
        guard let target = resolveSession(call.session) else {
            return errorOutcome(call, "Error: read_section requires a valid \"session\" tag (e.g. \"S1\").")
        }
        guard !target.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return errorOutcome(call, "Error: session \(target.tag) has no readable transcript.")
        }

        let startSec: Int
        let endSec: Int
        if let rawStart = call.start?.trimmingCharacters(in: .whitespacesAndNewlines), !rawStart.isEmpty {
            guard let parsed = Self.parseSeconds(rawStart), parsed >= 0 else {
                return errorOutcome(call, "Error: invalid \"start\" time \"\(rawStart)\" (expected MM:SS or seconds).")
            }
            startSec = parsed
        } else {
            startSec = 0
        }
        if let rawEnd = call.end?.trimmingCharacters(in: .whitespacesAndNewlines), !rawEnd.isEmpty {
            guard let parsed = Self.parseSeconds(rawEnd), parsed >= startSec else {
                return errorOutcome(call, "Error: invalid \"end\" time \"\(rawEnd)\" (must be >= start).")
            }
            endSec = parsed
        } else {
            // Saturates: a model-written start near Int.max must not trap.
            let (sum, overflow) = startSec.addingReportingOverflow(600)
            endSec = overflow ? Int.max : sum
        }

        let rangeLabel = "\(TranscriptTimeline.format(startSec))–\(TranscriptTimeline.format(endSec))"
        let allLines = target.transcript.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var matched: [String] = []
        var lastKnownSecond: Int?
        var anyTimed = false

        for line in allLines {
            if let sec = TranscriptTimeline.leadingSeconds(of: line) {
                anyTimed = true
                lastKnownSecond = sec
            }
            if let current = lastKnownSecond, current >= startSec && current <= endSec {
                matched.append(line)
            }
        }

        // Untimed transcript fallback: slice by section index (~10 min per section).
        if !anyTimed {
            let sections = TranscriptSections.split(target.transcript)
            let index = min(max(0, startSec / 600), max(0, sections.count - 1))
            if sections.indices.contains(index) {
                matched = [sections[index].text]
            }
        }

        let stage = "Read \(target.tag) [\(rangeLabel)]"
        guard !matched.isEmpty else {
            return LocalToolOutcome(
                call: call,
                isError: false,
                stageTitle: stage,
                output: "No transcript lines in \(target.tag) between \(rangeLabel).",
                readTranscriptTags: [],
                readDigestTags: []
            )
        }

        var body = TranscriptCompactor.compact(matched.joined(separator: "\n"))
        let header = "Transcript \(target.tag) (\(Self.dateFormatter.string(from: target.date))) [\(rangeLabel)]:\n"
        let limit = max(80, maxCharacters - header.count)
        if body.count > limit {
            body = String(body.prefix(limit - 15)) + "\n[…truncated]"
        }
        return LocalToolOutcome(
            call: call,
            isError: false,
            stageTitle: stage,
            output: header + body,
            readTranscriptTags: [target.tag],
            readDigestTags: []
        )
    }

    private func executeGetDigest(_ call: LocalToolCall, maxCharacters: Int) -> LocalToolOutcome {
        guard let target = resolveSession(call.session) else {
            return errorOutcome(call, "Error: get_digest requires a valid \"session\" tag (e.g. \"S1\").")
        }
        let stage = "Read digest for \(target.tag)"
        let header = "Digest for \(target.tag) (\(Self.dateFormatter.string(from: target.date))):\n"
        let limit = max(80, maxCharacters - header.count)

        if let digest = target.digest {
            var text = digest.sessionDigest
            if !digest.sections.isEmpty, text.count + 200 < limit {
                let sectionText = digest.sections.enumerated().map { idx, sec in
                    let range: String
                    if let s = sec.start, let e = sec.end {
                        range = "[\(TranscriptTimeline.format(s))–\(TranscriptTimeline.format(e))]"
                    } else {
                        range = "[part \(idx + 1)]"
                    }
                    return "\(range) \(sec.digest)"
                }.joined(separator: "\n")
                if (text.count + sectionText.count + 20) <= limit {
                    text += "\n\nSection details:\n" + sectionText
                }
            }
            if text.count > limit {
                text = String(text.prefix(limit - 15)) + "… [truncated]"
            }
            return LocalToolOutcome(
                call: call,
                isError: false,
                stageTitle: stage,
                output: header + text,
                readTranscriptTags: [],
                readDigestTags: [target.tag]
            )
        }

        if !target.notes.isEmpty {
            let body = String(target.notes.prefix(limit))
            return LocalToolOutcome(
                call: call,
                isError: false,
                stageTitle: stage,
                output: header + "(No stored session digest; showing session notes)\n" + body,
                readTranscriptTags: [],
                readDigestTags: []
            )
        }

        return LocalToolOutcome(
            call: call,
            isError: false,
            stageTitle: stage,
            output: header + "No digest is stored for \(target.tag). Use read_section or search on \(target.tag).",
            readTranscriptTags: [],
            readDigestTags: []
        )
    }

    private func executeListSessions(_ call: LocalToolCall, maxCharacters: Int) -> LocalToolOutcome {
        let rangeResult = parseDateBounds(from: call.from, to: call.to)
        if case .failure(let message) = rangeResult {
            return errorOutcome(call, message)
        }
        let bounds = (try? rangeResult.get()) ?? nil
        let filtered = sessions.filter { session in
            if let from = bounds?.from, session.date < from { return false }
            if let to = bounds?.to, session.date > to { return false }
            return true
        }.sorted { $0.date > $1.date }

        let stage = "Listed \(filtered.count) session\(filtered.count == 1 ? "" : "s")"
        guard !filtered.isEmpty else {
            return LocalToolOutcome(
                call: call,
                isError: false,
                stageTitle: stage,
                output: "No sessions in the requested date range.",
                readTranscriptTags: [],
                readDigestTags: []
            )
        }

        var lines: [String] = ["Sessions (\(filtered.count) total, newest first):"]
        var used = lines[0].count
        for s in filtered {
            let duration = TranscriptTimeline.lastSeconds(in: s.transcript).map(TranscriptTimeline.durationLabel) ?? "untimed"
            let flags = [
                s.digest != nil ? "digest" : nil,
                !s.notes.isEmpty ? "notes" : nil,
                !s.transcript.isEmpty ? "transcript (\(duration))" : "no transcript",
            ].compactMap { $0 }.joined(separator: ", ")
            let line = "- [\(s.tag)] \(Self.dateFormatter.string(from: s.date)) — \(flags)"
            if used + line.count + 1 > maxCharacters { break }
            lines.append(line)
            used += line.count + 1
        }
        return LocalToolOutcome(
            call: call,
            isError: false,
            stageTitle: stage,
            output: lines.joined(separator: "\n"),
            readTranscriptTags: [],
            readDigestTags: []
        )
    }

    // MARK: Helpers

    /// The paragraph of `text` that starts at line `start`: lines up to the next
    /// blank one, split as `SearchIndex.passages` splits notes.
    static func paragraph(in text: String, from start: Int) -> String {
        let lines = LineTable(text)
        guard start >= 0, start < lines.count else { return "" }
        var kept: [String] = []
        for index in start..<lines.count {
            let line = lines[index]
            if line.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    private func resolveSession(_ rawTag: String?) -> LocalToolSession? {
        guard let raw = rawTag?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return sessions.count == 1 ? sessions.first : nil
        }
        let cleaned = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if let exact = sessions.first(where: { $0.tag.uppercased() == cleaned }) {
            return exact
        }
        if let num = Int(cleaned), let match = sessions.first(where: { $0.tag.uppercased() == "S\(num)" }) {
            return match
        }
        if sessions.count == 1 && (cleaned == "THIS SESSION" || cleaned == "CURRENT" || cleaned == "SESSION") {
            return sessions.first
        }
        return nil
    }

    static func parseSeconds(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
        if let whole = Int(trimmed) { return whole }
        let parts = trimmed.split(separator: ":")
        if parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]), m >= 0, (0..<60).contains(s) {
            return TranscriptTimeline.seconds(fromParts: [m, s])
        }
        if parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]),
           h >= 0, (0..<60).contains(m), (0..<60).contains(s) {
            return TranscriptTimeline.seconds(fromParts: [h, m, s])
        }
        return nil
    }

    private func parseDateBounds(from rawFrom: String?, to rawTo: String?) -> Result<(from: Date?, to: Date?), ErrorMessage> {
        var fromDate: Date?
        var toDate: Date?
        if let rawFrom = rawFrom?.trimmingCharacters(in: .whitespacesAndNewlines), !rawFrom.isEmpty {
            guard let parsed = Self.isoParser.date(from: rawFrom) else {
                return .failure(ErrorMessage("Error: invalid \"from\" date \"\(rawFrom)\" (expected YYYY-MM-DD)."))
            }
            fromDate = parsed
        }
        if let rawTo = rawTo?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTo.isEmpty {
            guard let parsed = Self.isoParser.date(from: rawTo) else {
                return .failure(ErrorMessage("Error: invalid \"to\" date \"\(rawTo)\" (expected YYYY-MM-DD)."))
            }
            // Inclusive of the whole `to` day.
            toDate = parsed.addingTimeInterval(86_399)
        }
        if let f = fromDate, let t = toDate, f > t {
            return .failure(ErrorMessage("Error: \"from\" date must not be after \"to\" date."))
        }
        return .success((fromDate, toDate))
    }

    private struct ErrorMessage: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    private func errorOutcome(_ call: LocalToolCall, _ error: ErrorMessage) -> LocalToolOutcome {
        errorOutcome(call, error.text)
    }

    private func errorOutcome(_ call: LocalToolCall, _ message: String) -> LocalToolOutcome {
        LocalToolOutcome(
            call: call,
            isError: true,
            stageTitle: nil,
            output: message,
            readTranscriptTags: [],
            readDigestTags: []
        )
    }
}

// MARK: - Tool Loop Runner & Grammar (#286 Step 3b)

/// Runs the bounded, read-only local tool loop before streaming the final answer
/// when a session or patient history is too large to send in full.
enum LocalToolLoop {
    /// GBNF grammar constraining the built-in `llama.cpp` engine's tool-selection
    /// reply to `{"calls":[...]}` JSON so small local models cannot hallucinate prose
    /// or broken JSON when picking follow-up lookups.
    static let grammar = LocalLLMGrammar(
        label: "local_tools",
        gbnf: #"""
        root   ::= "{\"calls\":[" ws (call ("," ws call)*)? "]}" ws
        call   ::= "{\"tool\":" ws tool ("," ws arg)* "}" ws
        tool   ::= "\"search\"" | "\"read_section\"" | "\"get_digest\"" | "\"list_sessions\""
        arg    ::= "\"query\":" ws str | "\"session\":" ws str | "\"start\":" ws str | "\"end\":" ws str | "\"from\":" ws str | "\"to\":" ws str
        str    ::= "\"" char* "\"" ws
        char   ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4})
        ws     ::= [ \t\n]*
        """#
    )

    private struct Envelope: Decodable {
        let calls: [LocalToolCall]
    }

    /// Parses tool calls from a model reply (`{"calls":[...]}` or a single `{"tool":...}`
    /// JSON object, with or without surrounding markdown code fences).
    /// Malformed non-empty output that is not "none" returns a synthetic invalid call
    /// so `LocalToolScope.execute` reports a validation error instead of crashing.
    static func parseCalls(_ raw: String) -> [LocalToolCall] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()
        if lower == "none" || lower == "[]" || lower == "{}" || lower == "{\"calls\":[]}" {
            return []
        }

        // Strip optional ```json ... ``` fences or outer prose around the first { ... }.
        let candidate: String
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            candidate = String(trimmed[firstBrace...lastBrace])
        } else {
            candidate = trimmed
        }

        if let data = candidate.data(using: .utf8) {
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
                return envelope.calls
            }
            if let single = try? JSONDecoder().decode(LocalToolCall.self, from: data) {
                return [single]
            }
            if let array = try? JSONDecoder().decode([LocalToolCall].self, from: data) {
                return array
            }
        }
        return [LocalToolCall(tool: "invalid_json")]
    }

    /// Prompt asking the model which read-only local tools (if any) it needs before answering.
    static func planningPrompt(
        question: String,
        initialContext: String,
        priorToolOutputs: [String],
        remainingCalls: Int
    ) -> String {
        let priorBlock = priorToolOutputs.isEmpty
            ? ""
            : "\n\nResults from earlier tool lookups:\n" + priorToolOutputs.joined(separator: "\n\n")
        return """
        You are preparing to answer a clinician's question from recorded therapy sessions. \
        Not every transcript fit in the initial material below. You may request up to \
        \(remainingCalls) read-only local tool call\(remainingCalls == 1 ? "" : "s") to inspect \
        specific sections, digests, or search terms before writing your answer, or return \
        {"calls":[]} if the material below is already sufficient.

        Available read-only tools:
        - search: {"tool":"search","query":"<words>","from":"YYYY-MM-DD (optional)","to":"YYYY-MM-DD (optional)"}
        - read_section: {"tool":"read_section","session":"S1","start":"MM:SS","end":"MM:SS"}
        - get_digest: {"tool":"get_digest","session":"S1"}
        - list_sessions: {"tool":"list_sessions","from":"YYYY-MM-DD (optional)","to":"YYYY-MM-DD (optional)"}

        Respond ONLY with a JSON object of the form {"calls":[...]}. Do not write the final answer yet.

        Initial material:
        \(initialContext)\(priorBlock)

        Therapist's question: \(question)
        """
    }

    struct RefinementResult: Equatable {
        /// Additional context block to append to the material sent in the final answer prompt.
        let additionalContext: String
        /// All tool outcomes executed during the loop.
        let outcomes: [LocalToolOutcome]
        /// Session tags whose transcript passages were read via tools.
        let readTranscriptTags: Set<String>
        /// Session tags whose digests were read via tools.
        let readDigestTags: Set<String>
    }

    /// Runs up to `effort.maxRefinementRounds` (and at most `effort.maxToolCalls` total calls),
    /// reporting each tool lookup to `live` and bounding all results to `characterBudget`.
    @MainActor
    static func refine(
        question: String,
        initialContext: String,
        scope: LocalToolScope,
        effort: AnswerEffort,
        characterBudget: Int,
        service: AssistantService,
        builder: DigestBuilder,
        live: @escaping DigestBuilder.Live
    ) async throws -> RefinementResult {
        let maxCalls = effort.maxToolCalls
        let maxRounds = effort.maxRefinementRounds
        guard maxCalls > 0, maxRounds > 0, characterBudget > 200 else {
            return RefinementResult(additionalContext: "", outcomes: [], readTranscriptTags: [], readDigestTags: [])
        }

        var remainingCalls = maxCalls
        var remainingBudget = characterBudget
        var outcomes: [LocalToolOutcome] = []
        var outputs: [String] = []
        /// Successful outputs that fit `characterBudget`: the only ones the answer gets.
        var accepted: [String] = []
        var transcriptTags = Set<String>()
        var digestTags = Set<String>()
        var seenCalls: [LocalToolCall] = []

        for round in 0..<maxRounds {
            try Task.checkCancellation()
            guard remainingCalls > 0, remainingBudget > 200 else { break }

            let planPrompt = planningPrompt(
                question: question,
                initialContext: initialContext,
                priorToolOutputs: outputs,
                remainingCalls: remainingCalls
            )
            guard service.fits(prompt: planPrompt) else { break }

            let rawPlan: String
            do {
                rawPlan = try await builder.runStage(
                    planPrompt,
                    read: round == 0 ? "Checking what to look up" : "Checking follow-up lookups",
                    write: "Selecting passages",
                    task: .digest,
                    grammar: grammar,
                    service: service,
                    live: live
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // If the planning stage fails, fall back cleanly to the deterministic floor.
                break
            }

            let requested = Array(parseCalls(rawPlan).prefix(remainingCalls))
            guard !requested.isEmpty else { break }

            var madeProgress = false
            for call in requested {
                try Task.checkCancellation()
                guard remainingCalls > 0, remainingBudget > 120 else { break }
                if seenCalls.contains(call) { continue }
                seenCalls.append(call)

                let perCallBudget = max(240, min(2_400, remainingBudget))
                // A search reads every session of a long history: off the main thread.
                let outcome = await Task.detached(priority: .userInitiated) {
                    scope.execute(call, maxCharacters: perCallBudget)
                }.value
                remainingCalls -= 1
                outcomes.append(outcome)

                if let stage = outcome.stageTitle {
                    live(nil) { $0.recordCompletedStage(stage) }
                }

                // An output over the remaining budget is dropped: it reaches neither
                // the next round nor the answer, and its tags are not counted as read.
                let cost = outcome.output.count + 2
                if cost <= remainingBudget {
                    outputs.append(outcome.output)
                    remainingBudget -= cost
                    if !outcome.isError {
                        madeProgress = true
                        accepted.append(outcome.output)
                        transcriptTags.formUnion(outcome.readTranscriptTags)
                        digestTags.formUnion(outcome.readDigestTags)
                    }
                }
            }
            if !madeProgress { break }
        }

        let block = accepted.isEmpty
            ? ""
            : "Additional passages and digests from follow-up lookups:\n" + accepted.joined(separator: "\n\n")
        return RefinementResult(
            additionalContext: block,
            outcomes: outcomes,
            readTranscriptTags: transcriptTags,
            readDigestTags: digestTags
        )
    }
}

// MARK: - Long Single-Session Chat (#286 Steps 3a, 3b, 5b)

/// Answers a chat question about a single session when its transcript exceeds
/// the context budget. Short sessions that fit are passed straight through to
/// `service.streamAnswerAboutSession`. Overflow sessions use the session digest,
/// question-matched transcript passages, and (at `Normal` / `Focus`) the bounded
/// `LocalToolLoop`.
@MainActor
enum LongSessionChat {
    static let headerReserve = 1_200
    static let digestShare = 2_500
    static let fastMaterialLimit = 7_500

    static func stream(
        transcript: String,
        notes: String = "",
        comments: [SessionComment] = [],
        patientBackground: String = "",
        history: [ChatMessage],
        question: String,
        effort: AnswerEffort = .default,
        sessionID: UUID,
        sessionDate: Date = Date(),
        folderName: String = "",
        service: AssistantService,
        builder: DigestBuilder,
        loadDigest: @escaping () async -> SessionDigest?,
        saveDigest: @escaping (SessionDigest) throws -> Void,
        live: @escaping DigestBuilder.Live,
        coverage: @escaping (String?) -> Void
    ) -> AsyncThrowingStream<String, Error> {
        let commentLines = AssistantService.formatComments(comments)
        let system = Prompts.chatSystemPrompt(service.systemPrompt, question: question)
        func makePrompt(_ material: String) -> String {
            Prompts.sessionChat(
                transcript: material,
                notes: notes,
                comments: commentLines,
                patientBackground: patientBackground,
                history: history,
                question: question
            )
        }
        if service.budget.fits(promptCharacters: system.count + makePrompt(transcript).count) {
            coverage(nil)
            return service.streamAnswerAboutSession(
                transcript: transcript,
                notes: notes,
                comments: comments,
                patientBackground: patientBackground,
                history: history,
                question: question
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let digest: SessionDigest
                    if let stored = await loadDigest() {
                        digest = stored
                    } else {
                        let built = try await builder.buildInline(
                            sessionID: sessionID,
                            transcript: transcript,
                            service: service,
                            live: { started, change in
                                live(started) {
                                    change(&$0)
                                    if !$0.readTitle.hasPrefix("Building digest") {
                                        $0.readTitle = "Building digest · \($0.readTitle)"
                                    }
                                }
                            }
                        )
                        try? saveDigest(built)
                        digest = built
                    }

                    let total = service.budget.availableCharacters(
                        reserving: system.count + makePrompt("").count + headerReserve
                    )
                    guard total >= 600 else {
                        throw ContextBudgetError(minutes: service.budget.approximateMinutes)
                    }

                    let toolReserve = effort.maxToolCalls > 0 ? min(3_600, total / 3) : 0
                    let initialRoom: Int
                    switch effort {
                    case .fast:
                        initialRoom = min(total, fastMaterialLimit)
                    case .normal, .focus:
                        initialRoom = max(600, total - toolReserve)
                    }

                    let (digestText, _) = LongSessionNote.fit(
                        Prompts.longSessionDigest(digest.sessionDigest),
                        to: min(digestShare, max(200, initialRoom / 2))
                    )
                    let passageLimit = max(200, initialRoom - digestText.count)

                    let doc = SessionSearch.Document(
                        date: sessionDate,
                        tag: "S1",
                        kind: .transcript,
                        text: transcript,
                        session: sessionID
                    )
                    let searchResult = SessionSearch.search([doc], question: question, characterBudget: passageLimit)
                    var passageBlocks: [String] = []
                    var usedPassageChars = 0
                    var passageLineCount = 0
                    for hit in searchResult.hits {
                        let block = hit.context.joined(separator: "\n")
                        if usedPassageChars + block.count + 6 > passageLimit { break }
                        passageBlocks.append(block)
                        usedPassageChars += block.count + 6
                        passageLineCount += hit.context.count
                    }
                    if passageBlocks.isEmpty {
                        let lines = LongSessionNote.nonBlankLines(transcript).map(String.init)
                        var fallback: [String] = []
                        var chars = 0
                        let cap = min(passageLimit, 1_800)
                        for line in lines {
                            if chars + line.count + 1 > cap { break }
                            fallback.append(line)
                            chars += line.count + 1
                        }
                        if !fallback.isEmpty {
                            passageBlocks = [fallback.joined(separator: "\n")]
                            passageLineCount = fallback.count
                        }
                    }

                    let passagesText = passageBlocks.joined(separator: "\n[…]\n")
                    let searchStage = "Searched session · \(searchResult.hits.count) matching passage\(searchResult.hits.count == 1 ? "" : "s")"
                    live(nil) { $0.recordCompletedStage(searchStage) }

                    let baseMaterial = Prompts.longSessionMaterial(digest: digestText, passages: passagesText)
                    let totalLines = LongSessionNote.nonBlankLines(transcript).count
                    func makeCoverageLabel(toolLookups: Int) -> String {
                        var text = "Read: a summary of the whole session (\(digest.sections.count) part\(digest.sections.count == 1 ? "" : "s")) plus \(passageLineCount) of \(totalLines) transcript lines"
                        if toolLookups > 0 {
                            text += " and \(toolLookups) follow-up lookup\(toolLookups == 1 ? "" : "s")"
                        }
                        text += " · \(effort.displayName)."
                        return text
                    }
                    coverage(makeCoverageLabel(toolLookups: 0))

                    var finalMaterial = baseMaterial
                    if effort.maxToolCalls > 0 {
                        let scope = LocalToolScope(sessions: [
                            LocalToolSession(
                                id: sessionID,
                                tag: "S1",
                                date: sessionDate,
                                folderName: folderName,
                                transcript: transcript,
                                digest: digest,
                                notes: notes,
                                comments: commentLines
                            )
                        ])
                        let remainingForTools = max(0, total - baseMaterial.count - 80)
                        let refinement = try await LocalToolLoop.refine(
                            question: question,
                            initialContext: baseMaterial,
                            scope: scope,
                            effort: effort,
                            characterBudget: remainingForTools,
                            service: service,
                            builder: builder,
                            live: live
                        )
                        if !refinement.additionalContext.isEmpty {
                            finalMaterial += "\n\n" + refinement.additionalContext
                            let validCount = refinement.outcomes.filter { !$0.isError }.count
                            coverage(makeCoverageLabel(toolLookups: validCount))
                        }
                    }

                    var chatService = service
                    chatService.systemPrompt = system
                    _ = try await builder.runStage(
                        makePrompt(finalMaterial),
                        read: "Reading passages",
                        write: "Writing the answer",
                        task: .chat,
                        service: chatService,
                        live: live,
                        onSnapshot: { continuation.yield($0) }
                    )
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
}

// MARK: - Patient-Wide Chat Runner (#286 Steps 3b, 5, 5b)

/// Runs a patient-wide chat turn across all sessions. When every session's
/// transcript fit in full (`context.coverage.wholeTranscripts`), streams the
/// answer directly. Otherwise records the initial search stage, optionally runs
/// `LocalToolLoop.refine` (up to 4 tool calls at `Normal`, 10 at `Focus`, 0 at
/// `Fast`), updates `TranscriptCoverage`, and streams the final answer.
@MainActor
enum PatientChatAnswer {
    static let fastContextCap = 12_000

    static func toolReserve(for effort: AnswerEffort, budget: Int) -> Int {
        guard effort.maxToolCalls > 0 else { return 0 }
        return min(4_800, max(0, budget / 4))
    }

    static func initialContextBudget(for effort: AnswerEffort, totalBudget: Int) -> Int {
        switch effort {
        case .fast:
            return min(totalBudget, fastContextCap)
        case .normal, .focus:
            return max(2_000, totalBudget - toolReserve(for: effort, budget: totalBudget))
        }
    }

    static func stream(
        context: PatientContext,
        history: [ChatMessage],
        question: String,
        effort: AnswerEffort = .default,
        totalBudget: Int,
        scope: @escaping () async -> LocalToolScope,
        service: AssistantService,
        builder: DigestBuilder,
        live: @escaping DigestBuilder.Live,
        onCoverage: @escaping (TranscriptCoverage) -> Void
    ) -> AsyncThrowingStream<String, Error> {
        var baseCoverage = context.coverage
        baseCoverage.effort = effort

        if context.coverage.wholeTranscripts {
            onCoverage(baseCoverage)
            return service.streamAnswerAboutPatient(
                context: context.text,
                history: history,
                question: question
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    var currentCoverage = baseCoverage
                    onCoverage(currentCoverage)

                    let searchStage = "Searched \(currentCoverage.transcriptSessions) session\(currentCoverage.transcriptSessions == 1 ? "" : "s") · \(currentCoverage.sessionsWithPassages) session\(currentCoverage.sessionsWithPassages == 1 ? "" : "s") with passages"
                    live(nil) { $0.recordCompletedStage(searchStage) }

                    var finalContext = context.text
                    if effort.maxToolCalls > 0 {
                        let toolScope = await scope()
                        try Task.checkCancellation()
                        let remaining = max(0, totalBudget - context.text.count - 80)
                        let refinement = try await LocalToolLoop.refine(
                            question: question,
                            initialContext: context.text,
                            scope: toolScope,
                            effort: effort,
                            characterBudget: remaining,
                            service: service,
                            builder: builder,
                            live: live
                        )
                        try Task.checkCancellation()
                        if !refinement.additionalContext.isEmpty {
                            finalContext += "\n\n" + refinement.additionalContext
                            currentCoverage.sessionsWithPassages = min(
                                max(currentCoverage.transcriptSessions, refinement.readTranscriptTags.count),
                                max(currentCoverage.sessionsWithPassages, refinement.readTranscriptTags.count)
                            )
                            currentCoverage.digestSessions = max(
                                currentCoverage.digestSessions,
                                refinement.readDigestTags.count
                            )
                            onCoverage(currentCoverage)
                        }
                    }

                    let system = Prompts.chatSystemPrompt(service.systemPrompt, question: question)
                    let prompt = Prompts.patientChat(context: finalContext, history: history, question: question)
                    var chatService = service
                    chatService.systemPrompt = system
                    _ = try await builder.runStage(
                        prompt,
                        read: "Reading the sessions",
                        write: "Writing the answer",
                        task: .chat,
                        service: chatService,
                        live: live,
                        onSnapshot: { continuation.yield($0) }
                    )
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
}

