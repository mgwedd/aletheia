import Foundation

/// A single thing to expose to macOS Spotlight. Deliberately framework-free so
/// the "what do we index, and how does a hit route back into the app" logic is
/// unit-tested without CoreSpotlight.
///
/// Privacy: this app treats session audio and transcripts as PHI, so we never
/// put transcript or summary *content* into the system-wide index — only the
/// patient's name and session dates, and only when the user opts in (see
/// `AppSettings.spotlightIndexingEnabled`). Even that is a deliberate choice a
/// user makes, because a name in Spotlight is visible to anyone at the Mac.
struct SpotlightEntry: Equatable {
    let uniqueIdentifier: String
    let title: String
    let contentDescription: String
    let keywords: [String]
    /// Sorts the item by recency in Spotlight; nil for the patient card itself.
    let contentModificationDate: Date?
}

/// Where a tapped Spotlight result should take the user.
enum SpotlightRoute: Equatable {
    case patient(UUID)
    case session(patientID: UUID, folderName: String)
}

enum SpotlightItemBuilder {
    /// One domain so the whole index can be cleared in a single call when the
    /// user turns indexing off or switches data folders.
    static let domainIdentifier = "com.sessionnotes.index"

    private static let sessionTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()

    /// The searchable entries for one patient and their sessions: a card for
    /// the patient plus one per session. Metadata only — no transcript text.
    static func entries(for patient: Patient, sessions: [SessionRecord]) -> [SpotlightEntry] {
        var entries: [SpotlightEntry] = [
            SpotlightEntry(
                uniqueIdentifier: patientIdentifier(patient.id),
                title: patient.name,
                contentDescription: "Therapy patient in Aletheia.",
                keywords: keywords(for: patient),
                contentModificationDate: nil
            )
        ]

        for session in sessions {
            let dateString = sessionTitleFormatter.string(from: session.date)
            entries.append(
                SpotlightEntry(
                    uniqueIdentifier: sessionIdentifier(patientID: patient.id, folderName: session.folderName),
                    title: "\(patient.name) — \(dateString)",
                    contentDescription: "Therapy session on \(dateString).",
                    keywords: keywords(for: patient) + ["session"],
                    contentModificationDate: session.date
                )
            )
        }
        return entries
    }

    // MARK: - Identifiers

    static func patientIdentifier(_ id: UUID) -> String { "patient/\(id.uuidString)" }

    static func sessionIdentifier(patientID: UUID, folderName: String) -> String {
        "session/\(patientID.uuidString)/\(folderName)"
    }

    /// Parses a Spotlight item identifier back into a navigation target. Returns
    /// nil for anything malformed, so a stale index entry can't crash launch.
    static func route(forIdentifier identifier: String) -> SpotlightRoute? {
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "patient":
            guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
            return .patient(id)
        case "session":
            // folderName never contains "/", but rejoin defensively.
            guard parts.count >= 3, let id = UUID(uuidString: parts[1]) else { return nil }
            let folderName = parts[2...].joined(separator: "/")
            guard !folderName.isEmpty else { return nil }
            return .session(patientID: id, folderName: folderName)
        default:
            return nil
        }
    }

    private static func keywords(for patient: Patient) -> [String] {
        let nameTokens = patient.name
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .map(String.init)
        return nameTokens + ["therapy", "patient", "Aletheia"]
    }
}
