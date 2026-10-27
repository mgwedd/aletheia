import Foundation

/// When the app asks for recording consent.
enum ConsentPolicy: String, Codable, CaseIterable, Identifiable {
    /// Once per patient: their first recorded session asks, later ones don't.
    case firstSession
    /// Every session asks before it records.
    case everySession

    static let `default`: ConsentPolicy = .firstSession

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstSession: return "First session"
        case .everySession: return "Every session"
        }
    }
}

/// A policy choice that can also defer to the Settings default: what the
/// patient editor and Apply to Patients… offer.
enum ConsentPolicyChoice: String, CaseIterable, Identifiable {
    case useDefault, firstSession, everySession

    init(_ policy: ConsentPolicy?) {
        switch policy {
        case nil: self = .useDefault
        case .firstSession: self = .firstSession
        case .everySession: self = .everySession
        }
    }

    var id: String { rawValue }

    /// Nil means follow Settings.
    var policy: ConsentPolicy? {
        switch self {
        case .useDefault: return nil
        case .firstSession: return .firstSession
        case .everySession: return .everySession
        }
    }

    var title: String { policy?.title ?? "Use default" }
}

/// How consent was given.
enum ConsentMethod: String, Codable, CaseIterable, Identifiable {
    case verbal, written

    var id: String { rawValue }
    var title: String { self == .verbal ? "Verbal" : "Written" }
    var word: String { rawValue }
}

/// Who gave consent.
enum ConsentParty: String, Codable, CaseIterable, Identifiable {
    case patient
    case patientAndOthers
    case guardian
    case representative

    var id: String { rawValue }

    var title: String {
        switch self {
        case .patient: return "Patient"
        case .patientAndOthers: return "Patient and others present"
        case .guardian: return "Parent or guardian"
        case .representative: return "Other representative"
        }
    }

    /// As it reads after "from".
    var phrase: String {
        switch self {
        case .patient: return "the patient"
        case .patientAndOthers: return "the patient and others present"
        case .guardian: return "a parent or guardian"
        case .representative: return "a representative"
        }
    }

    /// Someone other than the patient, whose name is asked for.
    var needsName: Bool { self == .guardian || self == .representative }
}

/// The consent sealed into a session folder (`consent.json`). Written when the
/// clinician completes the consent sheet, and fixed once the session has a
/// signed note.
struct ConsentRecord: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = ConsentRecord.currentVersion
    var sessionID: UUID
    var patientID: UUID
    var party: ConsentParty
    /// The parent, guardian or representative; nil for the patient.
    var consenterName: String?
    var method: ConsentMethod
    /// When consent was given.
    var consentedAt: Date
    /// When it was entered in Aletheia.
    var recordedAt: Date
    /// The macOS user who entered it.
    var recordedBy: String
    /// The policy that asked for it.
    var policy: ConsentPolicy
    /// What the clinician confirmed, word for word.
    var statement: String

    /// "Consent: verbal, from the patient" (with the representative's name when given).
    var summary: String {
        var who = party.phrase
        if let name = consenterName, !name.isEmpty { who += " (\(name))" }
        return "Consent: \(method.word), from \(who)"
    }
}

/// What the consent sheet (and the menu bar panel) holds while it is being
/// filled in. The views bind to it; the rules live here so they are tested.
struct ConsentCapture: Equatable {
    var party: ConsentParty = .patient
    var name = ""
    var method: ConsentMethod = .verbal
    var consentedAt: Date
    var confirmed = false

    init(openedAt: Date = Date()) {
        consentedAt = openedAt
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Ticked, and a name entered when someone other than the patient consented.
    var isComplete: Bool { confirmed && (!party.needsName || !trimmedName.isEmpty) }

    /// The record this capture makes, with the consent time never later than `now`.
    func record(sessionID: UUID, patientID: UUID, policy: ConsentPolicy,
                now: Date = Date(), recordedBy: String = AuditLog.currentActor) -> ConsentRecord {
        ConsentRecord(
            sessionID: sessionID, patientID: patientID, party: party,
            consenterName: party.needsName ? trimmedName : nil, method: method,
            consentedAt: min(consentedAt, now), recordedAt: now, recordedBy: recordedBy,
            policy: policy, statement: RecordingConsent.attestationText)
    }
}

/// What a session shows about consent.
enum ConsentStatus: Equatable {
    /// The session has its own record.
    case recorded(ConsentRecord)
    /// No record of its own, but the patient consented before.
    case onFile(since: Date)
    /// Nothing recorded.
    case none
}

/// The consent sheet was confirmed before it was complete.
struct ConsentCaptureIncomplete: LocalizedError {
    var errorDescription: String? { RecordingConsent.notConfirmedMessage }
}

/// What the consent sheet is in front of: Record, or Import Audio.
enum ConsentSheetPurpose: Equatable {
    /// Before Record Session.
    case record
    /// Before Import Audio….
    case importAudio
    /// Change… on the session's consent line.
    case change

    /// The sheet's confirm button.
    var confirmTitle: String {
        switch self {
        case .record: return RecordingConsent.startRecordingTitle
        case .importAudio: return RecordingConsent.chooseAudioTitle
        case .change: return RecordingConsent.saveConsentTitle
        }
    }
}

/// Settings > Apply to Patients…: one policy choice for the patients ticked.
struct ConsentPolicyBulkEdit: Equatable {
    var choice: ConsentPolicyChoice = .everySession
    var selected: Set<UUID> = []

    /// Apply is off until at least one patient is ticked.
    var canApply: Bool { !selected.isEmpty }

    func allSelected(of ids: [UUID]) -> Bool { !ids.isEmpty && Set(ids).isSubset(of: selected) }

    /// The Select All toggle.
    mutating func selectAll(_ on: Bool, of ids: [UUID]) { selected = on ? Set(ids) : [] }

    mutating func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}
