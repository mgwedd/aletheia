import Foundation
import os

private let log = Logger(subsystem: "com.aletheia", category: "OrphanAudioSweep")

/// Scans for audio files that were orphaned by an abnormal termination (crash, power loss, force quit)
/// and restores them into their rightful sessions so no PHI is lost or left unencrypted.
///
/// Runs at app launch before transcription resumes:
/// 1. Scans the private staging directory (`Staging/<sessionUUID>/`). For known sessions, seals (or moves)
///    staged audio into the session folder and records `.recordingRecovered` in the audit log.
///    Unknown UUIDs are moved into `Staging/quarantine/<uuid>/` without deletion.
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
    }

    @discardableResult
    static func sweep(
        store: Store,
        protector: FileProtector,
        audit: AuditLog? = nil,
        ledger: InterruptedWorkLedger? = nil,
        stagingRoot: URL = Store.stagingDirectoryURL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Result {
        var result = Result()
        let fm = FileManager.default

        // 1. Sweep staging directory
        if fm.fileExists(atPath: stagingRoot.path) {
            let quarantineDir = stagingRoot.appendingPathComponent("quarantine", isDirectory: true)
            if !fm.fileExists(atPath: quarantineDir.path) {
                try? fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quarantineDir.path)
            }

            if let entries = try? fm.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: [.isDirectoryKey]) {
                for item in entries {
                    let name = item.lastPathComponent
                    guard name != "quarantine", !name.hasPrefix(".") else { continue }
                    guard let isDir = try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir else { continue }

                    guard let sessionUUID = UUID(uuidString: name) else {
                        // Not a valid UUID folder, quarantine it
                        let target = quarantineDir.appendingPathComponent(name, isDirectory: true)
                        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                        try? fm.moveItem(at: item, to: target)
                        result.quarantinedUnknownDirs += 1
                        continue
                    }

                    guard let found = store.locateSession(id: sessionUUID) else {
                        // Unknown UUID not found in store — quarantine, DO NOT delete!
                        let target = quarantineDir.appendingPathComponent(name, isDirectory: true)
                        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                        try? fm.moveItem(at: item, to: target)
                        result.quarantinedUnknownDirs += 1
                        continue
                    }

                    // Known session found: recover staged audio into session folder
                    let (patient, session) = found
                    let stageMic = item.appendingPathComponent("mic.caf")
                    let stageCall = item.appendingPathComponent("call.caf")
                    let destMic = store.micRecordingURL(for: patient, session: session)
                    let destCall = store.callRecordingURL(for: patient, session: session)

                    var recovered = false
                    for (src, dst) in [(stageMic, destMic), (stageCall, destCall)] {
                        guard fm.fileExists(atPath: src.path) else { continue }
                        do {
                            try protector.sealLargeFile(from: src, to: dst)
                            try? fm.removeItem(at: src)
                            recovered = true
                        } catch {
                            // On failure, keep plaintext in destination so audio isn't lost
                            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                            try? fm.moveItem(at: src, to: dst)
                            try? fm.removeItem(at: src)
                            recovered = true
                        }
                    }

                    // Clean up staging directory
                    try? fm.removeItem(at: item)

                    if recovered {
                        result.stagedSessionsRecovered += 1
                        audit?.record(.recordingRecovered, subjectID: session.id.uuidString, detail: "staged")
                        if let ledger, !session.hasTranscript {
                            ledger.record([InterruptedWork(kind: .transcription, patientID: patient.id, sessionFolder: session.folderName)])
                        }
                    }
                }
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
                                    log.error("Failed to seal legacy plaintext audio at \(audioURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                                }
                            }
                        }

                        if sealedAny {
                            result.legacySessionsSealed += 1
                            audit?.record(.recordingRecovered, subjectID: session.id.uuidString, detail: "legacy plaintext")
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
}
