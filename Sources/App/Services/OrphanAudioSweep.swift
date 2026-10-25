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
///    there on a later launch once their session can be found. A recording that can't be sealed stays staged,
///    and so does one whose session can't be ruled out because part of the folder couldn't be read.
///    Skips the session being recorded, and doesn't run at all while an encrypted folder is locked.
/// 2. Scans encrypted session folders for any legacy plaintext `.caf` files and seals them in place,
///    recording `.recordingRecovered`.
/// 3. Retries discarding the audio of sessions whose earlier discard after transcription failed
///    (marked by `markDiscardPending`), when the retention setting still says to discard and the
///    session has its transcript.
/// 4. Empties the private scratch folder (`PrivateStaging`) of decrypted or patient-derived temporary
///    files a crash left behind, and removes `aletheia-*.caf` copies older builds left in the shared
///    temporary directory.
enum OrphanAudioSweep {
    /// Result metrics for tests and diagnostic logging.
    struct Result: Equatable {
        var stagedSessionsRecovered: Int = 0
        var legacySessionsSealed: Int = 0
        var quarantinedUnknownDirs: Int = 0
        var temporaryFilesPurged: Int = 0
        /// Sessions whose audio was discarded after an earlier discard had failed.
        var audioDiscardsRetried: Int = 0
        /// The folder is encrypted but locked: nothing was touched, run again once unlocked.
        var skippedLocked = false
        /// Staged recordings left in place because part of the data folder couldn't be read.
        var stagedLeftForLater: Int = 0
    }

    /// Looks a staged recording's session up, asking twice before calling it
    /// unknown: setting audio aside on one miss would hide it until a later launch.
    private static func lookUp(_ id: UUID, in store: Store) -> Store.SessionLookup {
        let first = store.lookUpSession(id: id)
        if case .found = first { return first }
        return store.lookUpSession(id: id)
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
    ///   - discardsAudioAfterTranscription: the current retention setting; audio is only
    ///     retried for deletion while it says to discard.
    @discardableResult
    static func sweep(
        store: Store,
        protector: FileProtector,
        audit: AuditLog? = nil,
        ledger: InterruptedWorkLedger? = nil,
        activeSessionID: UUID? = nil,
        queuesTranscription: Bool = true,
        discardsAudioAfterTranscription: Bool = false,
        stagingRoot: URL = Store.stagingDirectoryURL,
        scratchRoot: URL = PrivateStaging.root,
        temporaryDirectory: URL = PrivateStaging.legacyTemporaryDirectory
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

                let lookup = sessionUUID.map { lookUp($0, in: store) } ?? .absent
                guard case let .found(patient, session) = lookup else {
                    // Part of the folder couldn't be read: the session may be there. Leave it staged for the next try.
                    if case .unsure = lookup, !isQuarantined {
                        result.stagedLeftForLater += 1
                        continue
                    }
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

        // 3. Retry discards that failed after transcription.
        result.audioDiscardsRetried = retryPendingDiscards(
            store: store, discards: discardsAudioAfterTranscription, stagingRoot: stagingRoot)

        // 4. Purge scratch-space and legacy shared-temp leftovers.
        result.temporaryFilesPurged = PrivateStaging.sweep(root: scratchRoot, legacyTemporaryDirectory: temporaryDirectory)

        return result
    }

    private static let discardMarkerPrefix = "discard-"

    private static func discardMarker(for sessionID: UUID, stagingRoot: URL) -> URL {
        stagingRoot.appendingPathComponent(discardMarkerPrefix + sessionID.uuidString)
    }

    /// Remembers that `sessionID`'s audio should be discarded but couldn't be, so a later
    /// launch retries. The marker lives in the private staging folder (not the session folder,
    /// which may be the very thing that can't be written) and holds no patient data.
    static func markDiscardPending(for sessionID: UUID, stagingRoot: URL = Store.stagingDirectoryURL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = discardMarker(for: sessionID, stagingRoot: stagingRoot)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }

    static func clearDiscardPending(for sessionID: UUID, stagingRoot: URL = Store.stagingDirectoryURL) {
        try? FileManager.default.removeItem(at: discardMarker(for: sessionID, stagingRoot: stagingRoot))
    }

    static func isDiscardPending(for sessionID: UUID, stagingRoot: URL = Store.stagingDirectoryURL) -> Bool {
        FileManager.default.fileExists(atPath: discardMarker(for: sessionID, stagingRoot: stagingRoot).path)
    }

    /// Deletes the audio of each marked session that has its transcript, while the setting
    /// still says to discard. A marker for a session this data folder doesn't have stays; one
    /// for a session whose audio the setting now keeps is dropped and the audio left alone.
    /// The deletion is recorded by `Store.deleteRecordings`.
    private static func retryPendingDiscards(store: Store, discards: Bool, stagingRoot: URL) -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)) ?? []
        var count = 0
        for marker in entries where marker.lastPathComponent.hasPrefix(discardMarkerPrefix) {
            guard let id = UUID(uuidString: String(marker.lastPathComponent.dropFirst(discardMarkerPrefix.count))) else { continue }
            guard discards else {
                try? FileManager.default.removeItem(at: marker)
                continue
            }
            guard let (patient, session) = store.locateSession(id: id), session.hasTranscript else { continue }
            do {
                try store.deleteRecordings(for: patient, session: session)
                try? FileManager.default.removeItem(at: marker)
                count += 1
            } catch {
                log.error("Couldn't discard the recording for session \(id.uuidString, privacy: .public); will retry at next launch")
            }
        }
        return count
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
