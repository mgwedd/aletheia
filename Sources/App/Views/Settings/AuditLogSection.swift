import SwiftUI

/// What the activity log says it records. The caption is built from this list,
/// and `AuditLogCopyTests` checks it against the places the app records events.
enum AuditLogCopy {
    /// Actions the app records today, with the phrase the caption uses for them.
    static let recorded: [(phrase: String, actions: [AuditAction])] = [
        ("app locks and unlocks (when app lock is on)", [.appUnlocked, .appUnlockFailed, .appLocked]),
        ("encryption changes", [.encryptionEnabled, .encryptionDisabled, .encryptionUnlocked]),
        ("exports", [.recordExported, .auditLogExported]),
        ("deletions", [.recordDeleted]),
        ("changes to security settings", [.securitySettingChanged]),
        ("changes to the data folder", [.dataFolderChanged]),
        ("recovery key and passphrase changes", [.encryptionKeyChanged, .encryptionPassphraseChanged]),
        ("repeated failed unlocks", [.repeatedUnlockFailures]),
        ("failed exports", [.exportFailed]),
        ("failed integrity checks", [.integrityCheckFailed]),
        ("backups", [.backupRun]),
        ("recovered recordings", [.recordingRecovered]),
        ("recording consent attestations", [.recordingConsentAttested]),
    ]

    static var recordedActions: Set<AuditAction> {
        Set(recorded.flatMap(\.actions))
    }

    /// Actions that exist but nothing records yet.
    static var notRecordedActions: [AuditAction] {
        AuditAction.allCases.filter { !recordedActions.contains($0) }
    }

    static var caption: String {
        let phrases = recorded.map(\.phrase)
        let list = phrases.dropLast().joined(separator: ", ") + ", and " + phrases[phrases.count - 1]
        return "An on-device record of \(list). Viewing records is not recorded yet. It holds no names or clinical content and never leaves this Mac. It supports, but does not by itself satisfy, HIPAA's audit-control requirement (§164.312(b))."
    }
}

/// Paging over a newest-first list of entries.
struct AuditLogPaging: Equatable {
    static let pageSize = 25
    var pageSize = AuditLogPaging.pageSize
    var total: Int
    var page = 0

    var pageCount: Int { max(1, (total + pageSize - 1) / pageSize) }
    var currentPage: Int { min(max(page, 0), pageCount - 1) }
    var range: Range<Int> {
        let start = currentPage * pageSize
        return start..<min(total, start + pageSize)
    }
    var hasNewer: Bool { currentPage > 0 }
    var hasOlder: Bool { currentPage < pageCount - 1 }
    var summary: String {
        total == 0 ? "" : "Showing \(range.lowerBound + 1)–\(range.upperBound) of \(total) entries, newest first."
    }
}

/// The security activity log in Settings: its caption, a paged list showing each
/// entry's detail, and the verify/export buttons.
struct AuditLogSection: View {
    @EnvironmentObject private var appModel: AppModel
    /// How the last export ended; shown by the Settings screen.
    @Binding var exportResult: SaveOutcome?
    /// Runs an export only after the user re-authenticates.
    let requireAuth: (SensitiveAction, @escaping @MainActor () -> Void) -> Void

    /// Newest first. A snapshot, loaded on appear and after an export.
    @State private var entries: [AuditEvent] = []
    @State private var page = 0
    @State private var verificationMessage: String?

    private var paging: AuditLogPaging { AuditLogPaging(total: entries.count, page: page) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Security audit log").eyebrowStyle()
            SettingsCaption(AuditLogCopy.caption)
            if entries.isEmpty {
                SettingsCard {
                    SettingsCaption("No activity recorded yet. App unlocks are only logged when app lock is on.")
                }
            } else {
                SettingsRowsCard {
                    ForEach(Array(entries[paging.range].enumerated()), id: \.offset) { item in
                        if item.offset > 0 { SettingsHairline() }
                        row(item.element)
                    }
                }
                HStack(spacing: 8) {
                    SettingsCaption(paging.summary)
                    Spacer()
                    Button("Newer") { page = paging.currentPage - 1 }
                        .buttonStyle(.themed)
                        .disabled(!paging.hasNewer)
                    Button("Older") { page = paging.currentPage + 1 }
                        .buttonStyle(.themed)
                        .disabled(!paging.hasOlder)
                }
            }
            HStack(spacing: 8) {
                Button("Verify integrity & export audit report") { requireAuth(.exportActivityLog) { verifyIntegrityAndExportReport() } }
                    .buttonStyle(.themed)
                    .disabled(entries.isEmpty)
                Button("Refresh", action: load)
                    .buttonStyle(.themed)
                Button("Export…") { requireAuth(.exportActivityLog) { exportLog() } }
                    .buttonStyle(.themed)
                    .disabled(entries.isEmpty)
                Spacer()
            }
            if let verificationMessage {
                SettingsCaption(verificationMessage)
            }
        }
        .onAppear(perform: load)
    }

    private func row(_ entry: AuditEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.action.displayName)
                    .foregroundStyle(Theme.text.color)
                Spacer()
                Text(Self.timestamp(entry))
                    .foregroundStyle(Theme.muted.color)
            }
            if let note = Self.detailLine(entry) {
                Text(note)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.Typography.caption)
        .padding(.vertical, 9)
    }

    /// The entry's note, actor and record id (shortened), or nil when it has none.
    static func detailLine(_ entry: AuditEvent) -> String? {
        var parts: [String] = []
        if let detail = entry.detail, !detail.isEmpty { parts.append(detail) }
        if entry.actor != AuditLog.unknownActor { parts.append("by \(entry.actor)") }
        if let subject = entry.subjectID { parts.append("record \(subject.prefix(8))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Loading and export

    /// `entries()` returns oldest first; reverse for a newest-first list.
    private func load() {
        entries = Array((appModel.audit?.entries() ?? []).reversed())
        page = min(page, paging.pageCount - 1)
    }

    private static func timestamp(_ entry: AuditEvent) -> String {
        guard let date = entry.date else { return entry.at }
        return dateFormatter.string(from: date)
    }

    /// Oldest-first text for the exported file.
    private func exportText() -> String {
        let all = appModel.audit?.entries() ?? []
        let header = """
        Aletheia security audit log (HIPAA §164.312(b)) — an on-device record with no PHI.
        Exported \(Self.dateFormatter.string(from: Date()))

        """
        let lines = all.map { entry -> String in
            let ts = entry.date.map { Self.dateFormatter.string(from: $0) } ?? entry.at
            var parts = ["\(ts)  \(entry.action.displayName)"]
            if let subject = entry.subjectID { parts.append("record \(subject)") }
            if let detail = entry.detail { parts.append(detail) }
            return parts.joined(separator: "  ·  ")
        }
        return header + lines.joined(separator: "\n") + "\n"
    }

    private func verifyIntegrityAndExportReport() {
        guard let audit = appModel.audit else { return }
        let status: String
        let result = audit.verifyIntegrity()
        switch result {
        case .verified(let count):
            status = "Integrity verified: all \(count) entries intact."
        case .broken(let seq, let reason):
            status = "Integrity check failed at entry #\(seq): \(reason)"
        case .unverifiable(let reason):
            status = "Audit log unverifiable: \(reason)"
        }
        verificationMessage = status
        appModel.applyIntegrityResult(result)
        let name = FileSaver.fileName("Aletheia Audit Report", Self.fileStamp())
        let outcome = FileSaver.saveText(audit.generateReport(status: status), suggestedName: "\(name).txt")
        finishExport(outcome)
    }

    private func exportLog() {
        let name = FileSaver.fileName("Aletheia Audit Log", Self.fileStamp())
        finishExport(FileSaver.saveText(exportText(), suggestedName: "\(name).txt"))
    }

    private func finishExport(_ outcome: SaveOutcome) {
        if case .saved = outcome {
            appModel.recordAudit(.auditLogExported)
            load()
        } else if case .failed = outcome {
            appModel.recordAudit(.exportFailed, detail: "Activity log")
            load()
        }
        exportResult = outcome.shown
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
