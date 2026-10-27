import Foundation

/// Where an effort level is applied: each has its own remembered setting
/// (`noteEffort`, `sessionChatEffort`, `patientChatEffort` in `AppSettings`)
/// and does slightly different work at each level.
enum EffortFeature: CaseIterable {
    case note
    case sessionChat
    case patientChat
}

/// How much work the assistant puts into a note or answer, remembered per
/// feature (`noteEffort`, `sessionChatEffort`, `patientChatEffort` in `AppSettings`).
///
/// Everything a level does is defined here, and the description the user sees
/// (`blurb(for:)`) is written from these same values, so the two can't drift.
/// At every level, material that fits this Mac's budget whole is read whole in
/// one pass: the levels only differ for a long session or history.
enum AnswerEffort: String, CaseIterable, Identifiable, Codable, Hashable {
    case fast
    case normal
    case focus

    static let `default`: AnswerEffort = .normal

    /// What the selector is called wherever it appears.
    static let label = "AI effort"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .focus: return "Focus"
        }
    }

    // MARK: - What each level does

    /// Maximum read-only lookups (`LocalToolLoop`) when refining a long-session
    /// or patient-wide answer. Lookups are local reads, not model calls. Notes make none.
    var maxToolCalls: Int {
        switch self {
        case .fast: return 0
        case .normal: return 4
        case .focus: return 10
        }
    }

    /// Maximum planning rounds before the answer: one model call each.
    var maxRefinementRounds: Int {
        switch self {
        case .fast: return 0
        case .normal: return 1
        case .focus: return 2
        }
    }

    /// Characters one lookup brings back when there is room for every lookup at full size.
    static let lookupCharacters = 2_000
    /// The least one lookup is given on a small Mac, where the reserve is split.
    static let minimumLookupCharacters = 600

    /// Characters kept free for lookups out of `total`, the room for material:
    /// every lookup at full size, but never more than a third of the room.
    func lookupReserve(total: Int) -> Int {
        guard maxToolCalls > 0 else { return 0 }
        return min(maxToolCalls * Self.lookupCharacters, max(0, total) / 3)
    }

    /// Characters one lookup may return out of `reserve`: an even share (less
    /// the two characters joining it to the next), so the last lookup has as much
    /// room as the first. Full size when the reserve allows it.
    func lookupCharacters(reserve: Int) -> Int {
        guard maxToolCalls > 0 else { return 0 }
        let share = max(0, reserve) / maxToolCalls - 2
        return max(Self.minimumLookupCharacters, min(Self.lookupCharacters, share))
    }

    /// Fast's cap, in characters, on what its one pass reads when the material
    /// is too long to send whole. Nil at the other levels: they use the room this Mac has.
    func materialCap(for feature: EffortFeature) -> Int? {
        guard self == .fast else { return nil }
        switch feature {
        case .note: return 8_000
        case .sessionChat: return 7_500
        case .patientChat: return 12_000
        }
    }

    /// Whether a long session's draft gets one more call that checks it against
    /// the passages it was written from. Only notes do this, and only at Focus.
    func checksDraft(for feature: EffortFeature) -> Bool {
        self == .focus && feature == .note
    }

    // MARK: - What the user is told

    /// What this level does for `feature`, written from the values above.
    func blurb(for feature: EffortFeature) -> String {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        let lookups = maxToolCalls > 0
            ? "up to \(plural(maxToolCalls, "lookup")) in \(plural(maxRefinementRounds, "round"))"
            : ""
        let cap = materialCap(for: feature).map { "about \(Self.grouped($0)) characters" } ?? ""
        switch (feature, self) {
        case (.note, .fast):
            return "Quickest: one pass. A session that fits is read whole; a longer one from its summary, its risk lines and the best passages, \(cap)."
        case (.note, .normal):
            return "One pass. A session that fits is read whole; a longer one from its summary, its risk lines and as many passages as fit. At Length Detailed, then \(lookups) to read parts in full."
        case (.note, .focus):
            return "Slowest. Like Normal, with \(lookups) to read parts in full at any length, then one more pass checks a long session's draft against the passages. A session that fits is read whole and not checked."
        case (.sessionChat, .fast):
            return "Quickest: one pass. A session that fits is read whole; a longer one from its summary and the passages search finds, \(cap)."
        case (.sessionChat, .normal):
            return "A session that fits is read whole. A longer one: its summary and the passages search finds, then \(lookups) to read parts closely."
        case (.sessionChat, .focus):
            return "Slowest. A session that fits is read whole. A longer one: like Normal, with \(lookups) and room kept for each."
        case (.patientChat, .fast):
            return "Quickest: one pass over the summaries, notes and search results, \(cap). A history that fits is read whole."
        case (.patientChat, .normal):
            return "Summaries, notes and search results, then \(lookups) to read the parts search points at. A history that fits is read whole."
        case (.patientChat, .focus):
            return "Slowest. Like Normal, with \(lookups) and room kept for each. A history that fits is read whole."
        }
    }

    /// `12000` as "12,000", the same on every Mac.
    static func grouped(_ n: Int) -> String {
        let digits = String(n)
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }
}
