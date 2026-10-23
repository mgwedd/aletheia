import CryptoKit
import Foundation
import Security

/// The kind of ePHI-affecting action recorded in the audit log. Coarse, PHI-free
/// categories — enough to answer "what touched patient data on this Mac, and
/// when" (HIPAA §164.312(b), "audit controls") without ever recording a name or
/// any clinical content.
enum AuditAction: String, Codable, CaseIterable {
    case appUnlocked
    case appUnlockFailed
    case encryptionEnabled
    case encryptionDisabled
    case encryptionUnlocked
    case recordExported
    case recordDeleted
    case backupRun
    case auditLogExported
    case phiViewed
    case phiCreated
    case phiAmended
    case phiDeleted
    case aiInference
    case phiCopied
    case backupRestored
    case appLocked
    case recordingConsentAttested
    case noteSigned
    case aiNoteVerified
    case recordingRecovered
    case retentionWarningOverridden
    case part2FlagChanged
    case securitySettingChanged
    case dataFolderChanged
    case encryptionKeyChanged
    case exportFailed
    case integrityCheckFailed
    case repeatedUnlockFailures

    /// Human-readable label for the log viewer.
    var displayName: String {
        switch self {
        case .appUnlocked: return "App unlocked"
        case .appUnlockFailed: return "App unlock failed"
        case .encryptionEnabled: return "Encryption enabled"
        case .encryptionDisabled: return "Encryption disabled"
        case .encryptionUnlocked: return "Encryption unlocked"
        case .recordExported: return "Record exported"
        case .recordDeleted: return "Record deleted"
        case .backupRun: return "Backup run"
        case .auditLogExported: return "Audit log exported"
        case .phiViewed: return "PHI viewed"
        case .phiCreated: return "PHI created"
        case .phiAmended: return "PHI amended"
        case .phiDeleted: return "PHI deleted"
        case .aiInference: return "AI inference"
        case .phiCopied: return "PHI copied"
        case .backupRestored: return "Backup restored"
        case .appLocked: return "App locked"
        case .recordingConsentAttested: return "Recording consent attested"
        case .noteSigned: return "Note signed"
        case .aiNoteVerified: return "AI note verified"
        case .recordingRecovered: return "Recording recovered"
        case .retentionWarningOverridden: return "Retention warning overridden"
        case .part2FlagChanged: return "Part 2 flag changed"
        case .securitySettingChanged: return "Security setting changed"
        case .dataFolderChanged: return "Data folder changed"
        case .encryptionKeyChanged: return "Recovery key or passphrase changed"
        case .exportFailed: return "Export failed"
        case .integrityCheckFailed: return "Integrity check failed"
        case .repeatedUnlockFailures: return "Repeated failed unlocks"
        }
    }
}

/// One row of the audit ledger. Deliberately free of PHI: it records the action,
/// actor ("username:uid"), timestamp, and at most an opaque record id (UUID)
/// and non-identifying detail note.
struct AuditEvent: Codable, Equatable {
    let seq: Int64?
    /// ISO 8601, UTC — unambiguous across time zones.
    let at: String
    /// The user and uid who performed the action: "\(NSUserName()):\(getuid())".
    let actor: String
    let action: AuditAction
    /// Opaque record UUID (patient or session), never a name.
    let subjectID: String?
    /// Short, non-PHI qualifier, e.g. "Markdown" or "imported". Never clinical.
    let detail: String?
    let appVersion: String
    /// Previous row's HMAC authentication tag, forming a cryptographic chain.
    let prevMac: Data?
    /// HMAC-SHA256 authentication tag over this entry and `prevMac`.
    let mac: Data?

    /// The parsed timestamp, for display and sorting.
    var date: Date? { AuditLog.isoFormatter.date(from: at) }

    enum CodingKeys: String, CodingKey {
        case seq, at, actor, action, subjectID, detail, appVersion, prevMac, mac
    }

    init(
        seq: Int64? = nil,
        at: String,
        actor: String = AuditLog.currentActor,
        action: AuditAction,
        subjectID: String? = nil,
        detail: String? = nil,
        appVersion: String = AppSettings.appVersionString,
        prevMac: Data? = nil,
        mac: Data? = nil
    ) {
        self.seq = seq
        self.at = at
        self.actor = actor
        self.action = action
        self.subjectID = subjectID
        self.detail = detail
        self.appVersion = appVersion
        self.prevMac = prevMac
        self.mac = mac
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decodeIfPresent(Int64.self, forKey: .seq)
        at = try container.decode(String.self, forKey: .at)
        // Lines from the old text log carry no actor; don't attribute them to
        // whoever happens to be running the app now.
        actor = (try container.decodeIfPresent(String.self, forKey: .actor)) ?? AuditLog.unknownActor
        action = try container.decode(AuditAction.self, forKey: .action)
        subjectID = try container.decodeIfPresent(String.self, forKey: .subjectID)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        appVersion = (try container.decodeIfPresent(String.self, forKey: .appVersion)) ?? AppSettings.appVersionString
        prevMac = try container.decodeIfPresent(Data.self, forKey: .prevMac)
        mac = try container.decodeIfPresent(Data.self, forKey: .mac)
    }
}

/// Result of checking the audit ledger's HMAC hash chain.
enum IntegrityVerificationResult: Equatable {
    case verified(count: Int)
    case broken(seq: Int64, reason: String)
    case unverifiable(reason: String)
}

/// Keychain and key derivation management for the HMAC ledger key.
enum AuditKeyManager {
    static let service = "Aletheia"
    static let account = "com.aletheia.audit-hmac-key"

    /// Load or create the HMAC key in Keychain.
    static func loadOrCreateKeychainKey() -> SymmetricKey? {
        guard TestHost.usesLiveKeychain() else { return testProcessKey }
        return loadOrCreate(load: readKeychainKey, add: addKeychainKey)
    }

    /// A new key is made only when the keychain says there is none. Any other
    /// read failure (keychain locked, access refused) returns nil and leaves the
    /// stored key alone: replacing it would make every row already signed with
    /// it fail verification for good. An add that races another writer re-reads
    /// the winner's key rather than overwriting it.
    static func loadOrCreate(
        load: () -> (status: OSStatus, key: SymmetricKey?),
        add: (SymmetricKey) -> OSStatus
    ) -> SymmetricKey? {
        let existing = load()
        if existing.status == errSecSuccess { return existing.key }
        guard existing.status == errSecItemNotFound else { return nil }
        let fresh = SymmetricKey(size: .bits256)
        switch add(fresh) {
        case errSecSuccess: return fresh
        case errSecDuplicateItem: return load().key
        default: return nil
        }
    }

    /// Stands in for the Keychain key while tests run (see `TestHost.usesLiveKeychain`).
    private static let testProcessKey = SymmetricKey(size: .bits256)

    static func loadKeychainKey() -> SymmetricKey? {
        guard TestHost.usesLiveKeychain() else { return testProcessKey }
        return readKeychainKey().key
    }

    private static func readKeychainKey() -> (status: OSStatus, key: SymmetricKey?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        // An item that isn't a 256-bit key is treated as unreadable, not absent,
        // so it is never silently replaced.
        guard let data = result as? Data, data.count == 32 else { return (errSecDecode, nil) }
        return (status, SymmetricKey(data: data))
    }

    private static func addKeychainKey(_ key: SymmetricKey) -> OSStatus {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// Derive K from the DEK via HKDF when Keychain is unavailable and encryption is on.
    static func deriveKey(fromDEK dek: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: dek,
            info: account.data(using: .utf8)!,
            outputByteCount: 32
        )
    }
}

/// An on-device, append-only, tamper-evident audit ledger of ePHI-affecting actions,
/// backed by SQLite (`audit_events` table) with HMAC-SHA256 hash chaining.
///
/// Each row records: `seq`, `at`, `actor`, `action`, `subject_id`, `detail`, `app_version`, `prev_mac`, `mac`.
/// `mac_i = HMAC-SHA256(K, prev_mac || at || actor || action || subject_id || detail || app_version)`
/// with length prefixing on each field to eliminate concatenation ambiguity.
///
/// Triggers `audit_no_update` and `audit_no_delete` prevent row modification or deletion.
/// Rows are never purged, even when patient records are removed.
final class AuditLog {
    static let fileName = "audit.log"
    static let legacyFileName = "audit.log"
    static let legacyImportedFileName = "audit.log.imported"

    let core: SQLitePersistenceCore?
    private let keyProvider: () -> SymmetricKey?
    private let dekProvider: (() -> SymmetricKey?)?
    private let queue = DispatchQueue(label: "com.aletheia.auditlog")
    private let writeStateLock = NSLock()
    private var writeFailed = false

    /// True while the most recent attempt to record an entry failed; the next
    /// successful write clears it. Surfaced in the security overview and as a
    /// banner so a broken log is never silent.
    var lastWriteFailed: Bool {
        writeStateLock.lock(); defer { writeStateLock.unlock() }
        return writeFailed
    }

    /// Called (on whichever thread wrote) when `lastWriteFailed` changes.
    var onWriteStateChanged: ((Bool) -> Void)?

    private func noteWrite(failed: Bool) {
        writeStateLock.lock()
        let changed = writeFailed != failed
        writeFailed = failed
        writeStateLock.unlock()
        if changed { onWriteStateChanged?(failed) }
    }

    static var currentActor: String {
        "\(NSUserName()):\(getuid())"
    }

    /// Actor for rows imported from the old text log, which never recorded one.
    static let unknownActor = "unknown"

    init(
        root: URL,
        core: SQLitePersistenceCore? = nil,
        keyProvider: @escaping () -> SymmetricKey? = AuditKeyManager.loadOrCreateKeychainKey,
        dekProvider: (() -> SymmetricKey?)? = nil
    ) {
        self.keyProvider = keyProvider
        self.dekProvider = dekProvider

        if let core {
            self.core = core
        } else {
            let dbURL = root.appendingPathComponent("Aletheia.sqlite")
            self.core = try? SQLitePersistenceCore(opening: dbURL)
        }

        importLegacyLogIfNeeded(root: root)
    }

    /// Resolves the HMAC signing key:
    /// 1. `keyProvider` — the Keychain key (account "com.aletheia.audit-hmac-key",
    ///    service "Aletheia") unless a test injects another
    /// 2. Derived from the DEK via HKDF (if encrypted and the DEK is available)
    /// 3. nil if neither is available (posture shows unverifiable, mac = NULL)
    func resolveKey() -> SymmetricKey? {
        candidateKeys().first
    }

    /// Every key a row may have been signed with, in signing preference order.
    /// Verification accepts a row tagged under any of them, so rows written
    /// during a spell when the Keychain was unreachable (signed with the
    /// DEK-derived key) don't read as tampered once it's back.
    private func candidateKeys() -> [SymmetricKey] {
        var keys: [SymmetricKey] = []
        if let key = keyProvider() { keys.append(key) }
        if let dek = dekProvider?() { keys.append(AuditKeyManager.deriveKey(fromDEK: dek)) }
        return keys
    }

    /// Whether the log has a key to compute and verify cryptographic HMAC tags.
    var isVerifiable: Bool {
        resolveKey() != nil
    }

    /// Append one event synchronously to the audit ledger.
    @discardableResult
    func record(
        _ action: AuditAction,
        subjectID: String? = nil,
        detail: String? = nil,
        at date: Date = Date(),
        appVersion: String = AppSettings.appVersionString
    ) throws -> AuditEvent {
        let row = SQLitePersistenceCore.NewAuditRow(
            at: Self.isoFormatter.string(from: date),
            actor: Self.currentActor,
            action: action.rawValue,
            subjectID: subjectID,
            detail: detail,
            appVersion: appVersion
        )
        let written: [SQLitePersistenceCore.AuditRow]
        do {
            written = try append([row])
        } catch {
            noteWrite(failed: true)
            throw error
        }
        noteWrite(failed: false)
        return Self.event(from: written[0])
    }

    /// Appends rows atomically, chained to the current tail (see
    /// `SQLitePersistenceCore.appendAuditEvents`).
    private func append(_ rows: [SQLitePersistenceCore.NewAuditRow]) throws -> [SQLitePersistenceCore.AuditRow] {
        try queue.sync {
            guard let core else {
                throw DatabaseOpenFailure(kind: .cannotOpen, reason: "Audit database core is unavailable")
            }
            let key = resolveKey()
            return try core.appendAuditEvents(rows) { prevMac, row in
                key.map { Self.computeMAC(key: $0, prevMac: prevMac, row: row) }
            }
        }
    }

    private static func event(from row: SQLitePersistenceCore.AuditRow) -> AuditEvent {
        AuditEvent(
            seq: row.seq,
            at: row.at,
            actor: row.actor,
            action: AuditAction(rawValue: row.action) ?? .appUnlocked,
            subjectID: row.subjectID,
            detail: row.detail,
            appVersion: row.appVersion,
            prevMac: row.prevMac,
            mac: row.mac
        )
    }

    /// All recorded events, oldest first.
    func entries() -> [AuditEvent] {
        queue.sync {
            guard let core else { return [] }
            return core.allAuditEvents().map(Self.event(from:))
        }
    }

    /// Recomputes the hash chain over all entries and reports whether verified,
    /// broken at a specific sequence number, or unverifiable.
    func verifyIntegrity() -> IntegrityVerificationResult {
        queue.sync {
            guard let core else {
                return .unverifiable(reason: "Database core unavailable")
            }
            let keys = candidateKeys()
            guard !keys.isEmpty else {
                return .unverifiable(reason: "Signing key is unavailable")
            }
            let rows = core.allAuditEvents()
            var expectedPrevMac: Data? = nil
            for row in rows {
                guard let rowMac = row.mac else {
                    return .unverifiable(reason: "Entry #\(row.seq) is missing cryptographic MAC")
                }
                if row.prevMac != expectedPrevMac {
                    return .broken(seq: row.seq, reason: "prev_mac does not match preceding entry's MAC")
                }
                let fields = SQLitePersistenceCore.NewAuditRow(
                    at: row.at, actor: row.actor, action: row.action,
                    subjectID: row.subjectID, detail: row.detail, appVersion: row.appVersion)
                let matches = keys.contains { key in
                    Self.computeMAC(key: key, prevMac: row.prevMac, row: fields) == rowMac
                }
                if !matches {
                    return .broken(seq: row.seq, reason: "MAC does not match row contents (tampered row)")
                }
                expectedPrevMac = rowMac
            }
            return .verified(count: rows.count)
        }
    }

    /// Generate an audit report with header, verification status, and entries.
    func generateReport(status: String? = nil) -> String {
        let all = entries()
        let verification = status ?? {
            switch verifyIntegrity() {
            case .verified(let count):
                return "Integrity verified: all \(count) entries intact"
            case .broken(let seq, let reason):
                return "Integrity check failed at entry #\(seq): \(reason)"
            case .unverifiable(let reason):
                return "Audit log unverifiable: \(reason)"
            }
        }()

        let header = """
        Aletheia security audit log (HIPAA §164.312(b)) — an on-device record with no PHI.
        Exported: \(Self.isoFormatter.string(from: Date()))
        Status: \(verification)

        """

        let lines = all.map { entry -> String in
            let seqStr = entry.seq.map { "#\($0)" } ?? "#?"
            let macStr = entry.mac?.prefix(8).map { String(format: "%02x", $0) }.joined() ?? "none"
            var parts = ["\(seqStr)  \(entry.at)  \(entry.actor)  \(entry.action.displayName)"]
            if let subject = entry.subjectID { parts.append("record \(subject)") }
            if let detail = entry.detail { parts.append(detail) }
            parts.append("mac: \(macStr)")
            return parts.joined(separator: "  ·  ")
        }

        return header + lines.joined(separator: "\n") + "\n"
    }

    /// Write an exported report to destination.
    func export(to destination: URL) throws {
        let text = generateReport()
        guard let data = text.data(using: .utf8) else { return }
        try data.write(to: destination, options: .atomic)
    }

    /// Encodes an event to JSON data. Exposed for tests.
    static func encodeLine(_ event: AuditEvent) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(event) else { return nil }
        return json + Data("\n".utf8)
    }

    // MARK: - Legacy import

    /// Moves the old text log's lines into the ledger, once. They go in as one
    /// transaction, and the file is set aside only after that succeeds: if the
    /// database can't be opened or written, the file stays put and the import is
    /// retried next launch rather than the lines being dropped. Each row keeps its
    /// original note, prefixed "imported", and an unknown actor.
    private func importLegacyLogIfNeeded(root: URL) {
        let fm = FileManager.default
        let legacyURL = root.appendingPathComponent(Self.legacyFileName)
        guard core != nil, fm.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL) else { return }

        let text = String(data: data, encoding: .utf8) ?? ""
        let decoder = JSONDecoder()
        let rows: [SQLitePersistenceCore.NewAuditRow] = text.split(separator: "\n").compactMap { line in
            guard let event = try? decoder.decode(AuditEvent.self, from: Data(line.utf8)) else { return nil }
            return SQLitePersistenceCore.NewAuditRow(
                at: event.at,
                actor: event.actor,
                action: event.action.rawValue,
                subjectID: event.subjectID,
                detail: event.detail.map { "imported · \($0)" } ?? "imported",
                appVersion: event.appVersion
            )
        }
        do {
            _ = try append(rows)
        } catch {
            return
        }
        // Never overwrite an earlier imported copy.
        var importedURL = root.appendingPathComponent(Self.legacyImportedFileName)
        var n = 2
        while fm.fileExists(atPath: importedURL.path) {
            importedURL = root.appendingPathComponent("\(Self.legacyImportedFileName)-\(n)")
            n += 1
        }
        try? fm.moveItem(at: legacyURL, to: importedURL)
    }

    // MARK: - Length-prefixed HMAC

    static func lengthPrefixed(_ data: Data?) -> Data {
        guard let data else {
            var marker = UInt32.max.bigEndian
            return Data(bytes: &marker, count: 4)
        }
        var len = UInt32(data.count).bigEndian
        var result = Data(bytes: &len, count: 4)
        result.append(data)
        return result
    }

    static func lengthPrefixed(_ string: String?) -> Data {
        lengthPrefixed(string?.data(using: .utf8))
    }

    static func computeMAC(
        key: SymmetricKey,
        prevMac: Data?,
        row: SQLitePersistenceCore.NewAuditRow
    ) -> Data {
        var payload = Data()
        payload.append(lengthPrefixed(prevMac))
        payload.append(lengthPrefixed(row.at))
        payload.append(lengthPrefixed(row.actor))
        payload.append(lengthPrefixed(row.action))
        payload.append(lengthPrefixed(row.subjectID))
        payload.append(lengthPrefixed(row.detail))
        payload.append(lengthPrefixed(row.appVersion))
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return Data(mac)
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
