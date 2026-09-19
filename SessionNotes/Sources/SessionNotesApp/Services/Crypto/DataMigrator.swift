import Foundation

/// Converts a data folder's existing PHI between plaintext and sealed form when
/// encryption is turned on or off — the bulk pass so a folder that already has
/// sessions in it isn't left half-protected.
///
///   enable:  migrate(from: .passthrough, to: <keyed>)   plaintext → sealed
///   disable: migrate(from: <keyed>,      to: .passthrough) sealed → plaintext
///
/// It knows the same layout `Store` writes:
///   Patients/<slug>/patient.json, patient_chat.json
///   Patients/<slug>/ChatThreads/<id>.json
///   Patients/<slug>/<…_Session>/{transcript.txt, summary.txt, chat.json,
///                                 mic.caf, call.caf}
///   SessionNotes.sqlite  (the comment/notes DB, field-level)
///
/// `session.json` (a session's id + date) is deliberately **not** in this list:
/// it's plaintext identity — no name or note text, and its date is already in
/// the cleartext folder name. Keeping it out means the encryption toggle can't
/// leave a session's id unreadable and orphan its annotations. Don't add it.
///
/// Text/JSON go through the one-shot cipher, audio through the streaming one,
/// and the database through `CommentStore.reencrypt`. Errors are collected per
/// item rather than aborting: a keyed protector reads plaintext and sealed
/// files alike, so a partially-converted folder still works and the pass can be
/// safely re-run.
enum DataMigrator {
    /// The `.caf` recordings, migrated with the streaming cipher.
    private static let audioNames = ["mic.caf", "call.caf"]
    /// The one-shot-sealed text/JSON files in a session folder.
    private static let sessionFileNames = ["transcript.txt", "summary.txt", "chat.json"]
    /// The one-shot-sealed files directly under a patient folder.
    private static let patientFileNames = ["patient.json", "patient_chat.json"]

    struct Result {
        var converted = 0
        var failures: [String] = []
        var isComplete: Bool { failures.isEmpty }
    }

    @discardableResult
    static func migrate(root: URL, from: FileProtector, to: FileProtector) -> Result {
        let fm = FileManager.default
        var result = Result()

        let patientsDir = root.appendingPathComponent("Patients", isDirectory: true)
        let patientDirs = (try? fm.contentsOfDirectory(at: patientsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for patientDir in patientDirs {
            guard (try? patientDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }

            for name in patientFileNames {
                migrateFile(patientDir.appendingPathComponent(name), from: from, to: to, into: &result)
            }

            // Chat threads live one-per-file under ChatThreads/ with dynamic
            // (UUID) names, so enumerate rather than use a fixed list.
            let threadsDir = patientDir.appendingPathComponent("ChatThreads", isDirectory: true)
            let threadFiles = (try? fm.contentsOfDirectory(at: threadsDir, includingPropertiesForKeys: nil)) ?? []
            for file in threadFiles where file.pathExtension == "json" {
                migrateFile(file, from: from, to: to, into: &result)
            }

            let sessionDirs = (try? fm.contentsOfDirectory(at: patientDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sessionDir in sessionDirs where sessionDir.lastPathComponent.hasSuffix("_Session") {
                for name in sessionFileNames {
                    migrateFile(sessionDir.appendingPathComponent(name), from: from, to: to, into: &result)
                }
                for name in audioNames {
                    migrateAudioFile(sessionDir.appendingPathComponent(name), from: from, to: to, into: &result)
                }
            }
        }

        // Database (field-level): decode with `from`, encode with `to`. Snapshot
        // first — a bulk PHI rewrite is exactly the kind of operation worth being
        // able to roll back if it's interrupted or fails partway.
        let dbURL = CommentStore.databaseURL(root: root)
        if fm.fileExists(atPath: dbURL.path) {
            if let store = CommentStore(root: root, protector: from) {
                DatabaseSnapshotManager(root: root).makeSnapshot(of: store, reason: "pre-encryption-change")
                if store.reencrypt(to: to) {
                    result.converted += 1
                } else {
                    result.failures.append("SessionNotes.sqlite")
                }
            } else {
                result.failures.append("SessionNotes.sqlite")
            }
        }

        return result
    }

    private static func migrateFile(_ url: URL, from: FileProtector, to: FileProtector, into result: inout Result) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try from.data(contentsOf: url)
            try to.write(data, to: url)
            result.converted += 1
        } catch {
            result.failures.append(url.lastPathComponent)
        }
    }

    private static func migrateAudioFile(_ url: URL, from: FileProtector, to: FileProtector, into result: inout Result) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            if to.isEncrypting {
                try to.sealLargeFileInPlace(at: url) // plaintext → sealed (no-op if already sealed)
            } else {
                // sealed → plaintext: decrypt with `from`, replace the original.
                let (readable, isTemp) = try from.decryptedCopyOfLargeFile(at: url)
                if isTemp { _ = try FileManager.default.replaceItemAt(url, withItemAt: readable) }
            }
            result.converted += 1
        } catch {
            result.failures.append(url.lastPathComponent)
        }
    }
}
