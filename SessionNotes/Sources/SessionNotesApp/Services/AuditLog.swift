import Foundation

/// The kind of ePHI-affecting action recorded in the audit log. Coarse, PHI-free
/// categories — enough to answer "what touched patient data on this Mac, and
/// when" (HIPAA §164.312(b), "audit controls") without ever recording a name or
/// any clinical content.
enum AuditAction: String, Codable, CaseIterable {
    case appUnlocked
    case encryptionEnabled
    case encryptionDisabled
    case encryptionUnlocked
    case recordExported
    case recordDeleted
    case backupRun
    case auditLogExported

    /// Human-readable label for the log viewer.
    var displayName: String {
        switch self {
        case .appUnlocked: return "App unlocked"
        case .encryptionEnabled: return "Encryption enabled"
        case .encryptionDisabled: return "Encryption disabled"
        case .encryptionUnlocked: return "Encryption unlocked"
        case .recordExported: return "Record exported"
        case .recordDeleted: return "Record deleted"
        case .backupRun: return "Backup run"
        case .auditLogExported: return "Audit log exported"
        }
    }
}

/// One line of the audit log. Deliberately free of PHI: it records the action
/// and the time, and at most an *opaque* record id (a patient/session UUID) and
/// a short non-identifying note — never a patient name, a transcript, or any
/// clinical text. The id is meaningful only alongside the data folder it already
/// lives in, so the log reveals nothing the folder structure doesn't.
struct AuditEvent: Codable, Equatable {
    /// ISO 8601, UTC — grep-friendly and unambiguous across time zones.
    let at: String
    let action: AuditAction
    /// Opaque record UUID (patient or session), never a name. Optional: some
    /// actions (app unlocked, encryption toggled) aren't about one record.
    let subjectID: String?
    /// Short, non-PHI qualifier, e.g. "Markdown" or "iCloud". Never clinical.
    let detail: String?
    let appVersion: String

    /// The parsed timestamp, for display and sorting. `nil` if a hand-edited
    /// line has an unparseable date.
    var date: Date? { AuditLog.isoFormatter.date(from: at) }
}

/// An on-device, append-only audit log of ePHI-affecting actions, written into
/// the user's own data folder as `audit.log` (one JSON object per line).
///
/// Honest scope, like `LegalReceipt`: a good-faith local record, not tamper-proof
/// and not proof of *who* was at the keyboard — no local store can be either. Its
/// value is that it's human-readable, durable, portable with a backup of the data
/// folder, and — per HIPAA §164.312(b) — examinable and exportable. It never
/// leaves the Mac.
///
/// It stays plaintext even when Tier-2 at-rest encryption is on, because by
/// construction it holds no PHI (no names, no clinical text — only action types,
/// timestamps, opaque record ids and short non-identifying notes). Writing is
/// best-effort: a write failure means no line that time, never a blocked action.
final class AuditLog {
    static let fileName = "audit.log"

    private let url: URL
    // Serialises appends/reads so concurrent actions can't interleave a line.
    private let queue = DispatchQueue(label: "com.sessionnotes.auditlog")

    init(root: URL) {
        url = root.appendingPathComponent(Self.fileName)
    }

    /// Append one event. Never throws.
    func record(
        _ action: AuditAction,
        subjectID: String? = nil,
        detail: String? = nil,
        at date: Date = Date(),
        appVersion: String = AppSettings.appVersionString
    ) {
        let event = AuditEvent(
            at: Self.isoFormatter.string(from: date),
            action: action,
            subjectID: subjectID,
            detail: detail,
            appVersion: appVersion
        )
        guard let line = Self.encodeLine(event) else { return }
        queue.sync { Self.write(line, to: url) }
    }

    /// All recorded events, oldest first (file order). A line that won't parse
    /// (e.g. hand-edited) is skipped rather than failing the whole read.
    func entries() -> [AuditEvent] {
        let data = queue.sync { (try? Data(contentsOf: url)) ?? Data() }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(AuditEvent.self, from: Data(line.utf8))
        }
    }

    /// Write a copy of the log to `destination` for the user to keep or hand to a
    /// compliance reviewer. Overwrites any existing file at that path. An empty
    /// log writes an empty file rather than failing.
    func export(to destination: URL) throws {
        let data = queue.sync { (try? Data(contentsOf: url)) ?? Data() }
        try data.write(to: destination, options: .atomic)
    }

    /// Encodes an event to a single newline-terminated JSON line. Exposed for
    /// tests; sorted keys keep the line stable and grep-friendly.
    static func encodeLine(_ event: AuditEvent) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(event) else { return nil }
        return json + Data("\n".utf8)
    }

    private static func write(_ data: Data, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // No file yet (or it couldn't be opened): create it with this line.
            try? data.write(to: url, options: .atomic)
        }
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
