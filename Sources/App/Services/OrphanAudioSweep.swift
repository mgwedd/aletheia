import Foundation
import os

private let log = Logger(subsystem: "com.aletheia", category: "OrphanAudioSweep")

/// Scans for audio files that were orphaned by an abnormal termination (crash, power loss, force quit)
/// and restores them into their rightful sessions so no PHI is lost or left unencrypted.
///
/// Runs at app launch before transcription resumes:
/// 1. Scans the private staging directory (`Staging/<sessionUUID>/`). For known sessions, seals (or moves)
///    staged audio into the session folder and records `.recordingRecovered` in the audit log.
///    Unknown UUIDs are moved into `Staging/quarantine/<uuid>/` without deletion, and recovered from
///    there on a later launch once their session can be found. A recording that can't be sealed stays staged.
///    Skips the session being recorded, and doesn't run at all while an encrypted folder is locked.
/// 2. Scans encrypted session folders for any legacy plaintext `.caf` files and seals them in place,
///    recording `.recordingRecovered`.
/// 3. Purges any leftover decrypted `aletheia-*.caf` files in the temporary directory.
enum OrphanAudioSweep {
    /// Result metrics for tests and diagnostic logging.
    struct Result: Equatable {
        var stagedSessionsRecovered: Int = 0
        var legacySessionsSealed: Int = 0
        var quarantinedUnknownDirs: Int = 0
        var temporaryFilesPurged: Int = 0
        /// The folder is encrypted but locked: nothing was touched, run again once unlocked.
        var skippedLocked = false
    }

    /// Whether the sweep can run with `protector`: not while an encrypted folder
    /// is locked, when sessions can't be read (so every staged recording would
    /// look unknown) and nothing could be sealed.
    static func canRun(with protector: FileProtector) -> Bool {
        !(protector.requiresProtection && !protector.isEncrypting)
    }

    /// - Parameters:
    ///   - activeSessionID: the session being recorded (or starting) right now;
    ///     its staging folder is left alone.
    ///   - queuesTranscription: whether a recovered session without a transcript
    ///     is listed for transcription (the "transcribe after recording" setting).
    @discardableResult
    static func sweep(
        store: Store,
        protector: FileProtector,
        audit: AuditLog? = nil,
        ledger: InterruptedWorkLedger? = nil,
        activeSessionID: UUID? = nil,
        queuesTranscription: Bool = true,
        stagingRoot: URL = Store.stagingDirectoryURL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Result {
        var result = Result()
        guard canRun(with: protector) else {
            result.skippedLocked = true
            return result
        }
        let fm = FileManager.default

        // 1. Sweep the staging directory, and the quarantine for sessions that can now be found.
        if fm.fileExists(atPath: stagingRoot.path) {
            let quarantineDir = quarantineDirectory(stagingRoot: stagingRoot)
            let staged = directories(in: stagingRoot).filter { $0.lastPathComponent != "quarantine" }
            let quarantined = directories(in: quarantineDir)

            for (item, isQuarantined) in staged.map({ ($0, false) }) + quarantined.map({ ($0, true) }) {
                let name = item.lastPathComponent
                // A folder set aside twice is named "<session id>-<random id>".
                let sessionUUID = UUID(uuidString: isQuarantined ? String(name.prefix(36)) : name)
                if let sessionUUID, sessionUUID == activeSessionID { continue }

                guard let sessionUUID, let found = store.locateSession(id: sessionUUID) else {
                    // Unknown here (another data folder, or a deleted session): keep it, never delete.
                    if !isQuarantined {
                        try? fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quarantineDir.path)
                        var target = quarantineDir.appendingPathComponent(name, isDirectory: true)
                        if fm.fileExists(atPath: target.path) {
                            target = quarantineDir.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
                        }
                        if (try? fm.moveItem(at: item, to: target)) != nil { result.quarantinedUnknownDirs += 1 }
                    }
                    continue
                }

                // Known session: recover the staged audio into its folder.
                let (patient, session) = found
                // A set-aside take never replaces a recording the session has since gained.
                if recover(item, into: patient, session: session, store: store, protector: protector, overwrites: !isQuarantined) {
                    result.stagedSessionsRecovered += 1
                    _ = try? audit?.record(.recordingRecovered, subjectID: session.id.uuidString, detail: "staged")
                    if let ledger, queuesTranscription, !session.hasTranscript {
                        ledger.record([InterruptedWork(kind: .transcription, patientID: patient.id, sessionFolder: session.folderName)])
                    }
                }
            }
            if result.stagedSessionsRecovered > 0 || result.quarantinedUnknownDirs > 0 {
                NotificationCenter.default.post(name: .setAsideRecordingsMayHaveChanged, object: nil)
            }
        }

        // 2. Sweep legacy plaintext .caf files in encrypted session folders
        if protector.isEncrypting {
            if let patients = try? store.listPatients() {
                for patient in patients {
                    guard let sessions = try? store.listSessions(for: patient) else { continue }
                    for session in sessions {
                        let micURL = store.micRecordingURL(for: patient, session: session)
                        let callURL = store.callRecordingURL(for: patient, session: session)
                        var sealedAny = false

                        for audioURL in [micURL, callURL] {
                            guard fm.fileExists(atPath: audioURL.path) else { continue }
                            if !ChunkedCipher.isEnvelope(fileAt: audioURL) {
                                do {
                                    try protector.sealLargeFileInPlace(at: audioURL)
                                    sealedAny = true
                                } catch {
                                    log.error("Couldn't seal a plaintext recording for session \(session.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                                }
                            }
                        }

                        if sealedAny {
                            result.legacySessionsSealed += 1
                            _ = try? audit?.record(.recordingRecovered, subjectID: session.id.uuidString, detail: "legacy plaintext")
                        }
                    }
                }
            }
        }

        // 3. Purge temporaryDirectory/aletheia-*.caf leftovers
        if let tempFiles = try? fm.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil) {
            for file in tempFiles {
                let name = file.lastPathComponent
                if name.hasPrefix("aletheia-") && name.hasSuffix(".caf") {
                    try? fm.removeItem(at: file)
                    result.temporaryFilesPurged += 1
                }
            }
        }

        return result
    }

    /// Seals the recordings in `item` into `session`'s folder and removes them
    /// from `item`. A file that can't be sealed stays where it is (and so does
    /// `item`); the next try picks it up. Unless `overwrites`, a file whose
    /// destination already exists stays too. Returns whether anything was recovered.
    @discardableResult
    static func recover(
        _ item: URL,
        into patient: Patient,
        session: SessionRecord,
        store: Store,
        protector: FileProtector,
        overwrites: Bool = true
    ) -> Bool {
        let fm = FileManager.default
        var recovered = false
        var kept = false
        for (file, dst) in [
            ("mic.caf", store.micRecordingURL(for: patient, session: session)),
            ("call.caf", store.callRecordingURL(for: patient, session: session)),
        ] {
            let src = item.appendingPathComponent(file)
            guard fm.fileExists(atPath: src.path) else { continue }
            if !overwrites && fm.fileExists(atPath: dst.path) {
                kept = true
                continue
            }
            do {
                try protector.sealLargeFile(from: src, to: dst)
                try? fm.removeItem(at: src)
                recovered = true
            } catch {
                kept = true
                log.error("Couldn't recover a staged recording for session \(session.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if !kept { try? fm.removeItem(at: item) }
        return recovered
    }

    /// Tries the set-aside recordings again (after switching data folder, or
    /// once a session is back): recovers each one whose session can now be
    /// found. Never touches the staging folders of recordings in progress.
    /// Returns how many were recovered.
    @discardableResult
    static func retrySetAside(
        store: Store,
        protector: FileProtector,
        audit: AuditLog? = nil,
        stagingRoot: URL = Store.stagingDirectoryURL
    ) -> Int {
        guard canRun(with: protector) else { return 0 }
        var count = 0
        for item in directories(in: quarantineDirectory(stagingRoot: stagingRoot)) {
            guard let id = UUID(uuidString: String(item.lastPathComponent.prefix(36))),
                  let (patient, session) = store.locateSession(id: id),
                  // Being recorded, or a take still waiting to be saved: leave it for later.
                  !FileManager.default.fileExists(atPath: Store.stagingDir(for: session.id, in: stagingRoot).path)
            else { continue }
            if recover(item, into: patient, session: session, store: store, protector: protector, overwrites: false) {
                count += 1
                _ = try? audit?.record(.recordingRecovered, subjectID: session.id.uuidString, detail: "set aside")
            }
        }
        NotificationCenter.default.post(name: .setAsideRecordingsMayHaveChanged, object: nil)
        return count
    }

    enum ManualRecoveryError: LocalizedError {
        case sessionHasRecording
        case nothingRecovered

        var errorDescription: String? {
            switch self {
            case .sessionHasRecording: return "That session already has a recording, or one is being saved. Choose another session."
            case .nothingRecovered: return "The recording couldn't be encrypted into that session. It's still set aside."
            }
        }
    }

    /// Puts a set-aside recording into a session the user picked. Refuses a
    /// session that already has a recording (or one still being saved), so
    /// nothing is overwritten.
    static func recoverSetAside(
        _ item: URL,
        into patient: Patient,
        session: SessionRecord,
        store: Store,
        protector: FileProtector,
        audit: AuditLog? = nil,
        stagingRoot: URL = Store.stagingDirectoryURL
    ) throws {
        let fm = FileManager.default
        let busy = [store.micRecordingURL(for: patient, session: session), store.callRecordingURL(for: patient, session: session)]
            .contains { fm.fileExists(atPath: $0.path) }
            || fm.fileExists(atPath: Store.stagingDir(for: session.id, in: stagingRoot).path)
        guard !busy else { throw ManualRecoveryError.sessionHasRecording }
        let recovered = recover(item, into: patient, session: session, store: store, protector: protector)
        NotificationCenter.default.post(name: .setAsideRecordingsMayHaveChanged, object: nil)
        guard recovered else { throw ManualRecoveryError.nothingRecovered }
        _ = try? audit?.record(.recordingRecovered, subjectID: session.id.uuidString, detail: "set aside, chosen session")
    }

    /// Where recordings whose session can't be found are kept.
    static func quarantineDirectory(stagingRoot: URL = Store.stagingDirectoryURL) -> URL {
        stagingRoot.appendingPathComponent("quarantine", isDirectory: true)
    }

    static func directories(in dir: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.filter {
            !$0.lastPathComponent.hasPrefix(".")
                && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }
    }
}

extension Notification.Name {
    /// Posted when recordings may have been set aside or recovered, so the
    /// set-aside warning re-checks.
    static let setAsideRecordingsMayHaveChanged = Notification.Name("com.aletheia.setAsideRecordingsMayHaveChanged")
}
