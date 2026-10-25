@testable import Aletheia
import AppKit
import Foundation
import XCTest

// MARK: - Subjects

/// What Settings offers for encryption in the current build.
struct EncryptionControls {
    let offered: Bool
}

/// A passphrase typed into the Turn On sheet.
struct TypedPassphrase {
    let canContinue: Bool
    let rating: PassphraseStrength
    let turnOnRefused: Bool
}

/// The recovery key step: the words and what the buttons do with them.
struct RecoveryKeyStep {
    let words: [String]
    let isAValidKey: Bool
    let clipboard: NamedClipboard
    let savedInsideDataFolder: SaveOutcome
    let savedElsewhere: SaveOutcome
}

/// A patient's session with a transcript, a note and a recording on disk.
struct SeededSession {
    let patient: Patient
    let session: SessionRecord
    let secret: String
}

/// The data folder the way Terminal sees it.
struct FolderInTerminal {
    let probe: DataFolderProbe
    let secret: String
    let patientFolder: String
    let sessionFolder: String

    var secretReadable: Bool { probe.containsPlaintext(secret) }
    var folderNamesReadable: Bool {
        let files = probe.files()
        return files.contains { $0.contains("\(patientFolder)/\(sessionFolder)/") }
    }
}

/// What a reopened app shows before and after the passphrase.
@MainActor
struct ReopenedFolder {
    let app: InProcessDriver

    var cover: LockCoverPolicy.Cover? {
        LockCoverPolicy.topCover(
            appLocked: false, hasDataFolder: true, encryption: app.encryption.state)
    }
}

/// A run of passphrase attempts on a locked folder.
struct UnlockAttempts {
    let messages: [String]
    let retryDelay: TimeInterval
    let correctOneRefusedDuringWait: String?
}

/// After changing the passphrase, which ways in still work.
struct ChangedPassphrase {
    let wrongCurrentRefused: Bool
    let oldOpens: Bool
    let newOpens: Bool
    let recoveryKeyOpens: Bool
    let secretStillReadable: Bool
}

/// The outcome of turning encryption off.
struct EncryptionTurnedOff {
    let refusedWithUnreadableFile: Bool
    let keyKeptWhileFileUnreadable: Bool
    let stillEncryptedWhileFileUnreadable: Bool
    let secretReadableOnDisk: Bool
    let keystoreRemoved: Bool
    let noLongerEncrypted: Bool
}

/// A recording stopped after the folder locked.
struct RecordingStoppedWhileLocked {
    let probe: DataFolderProbe
    let sessionFolder: URL
    let stagedAudio: URL
    let originalAudio: Data
    let stagingRoot: URL
    let seeded: SeededSession
    let transcriptionStarted: Bool
    let recorderFailedVisibly: Bool
}

/// What reopening does with audio left in staging.
struct ReopenedStaging {
    let recovered: Int
    let audioInSessionFolder: Bool
    let readsBack: Bool
    let stagedLeft: Bool
}

// MARK: - Given

enum EncryptionFixtures {
    static let passphrase = "correct horse battery staple"
    static let iterations = 100_000
}

extension Given {
    /// A patient with a transcript, a note and a recording, all in the clear.
    func aSession(withSecret secret: String) async throws -> SeededSession {
        let patient = try XCTUnwrap(app.appModel.addPatient(name: "Jane Doe"), "could not add a patient")
        let store = try XCTUnwrap(app.appModel.store)
        let session = try store.createSession(for: patient, on: app.clock.now)
        try store.saveTranscript("Transcript: \(secret)", for: patient, session: session)
        try store.saveNote("Note: \(secret)", for: patient, session: session, format: .narrative)
        try Data("audio: \(secret)".utf8).write(to: store.micRecordingURL(for: patient, session: session))
        return SeededSession(patient: patient, session: session, secret: secret)
    }

    /// Encryption on for the data folder, with a recovery key.
    @discardableResult
    func encryptionOn() throws -> String {
        let recoveryKey = RecoveryKey.generate()
        try app.encryption.enable(
            passphrase: EncryptionFixtures.passphrase, recoveryKey: recoveryKey,
            iterations: EncryptionFixtures.iterations)
        try app.encryption.rememberOnDevice()
        return recoveryKey
    }

    func unlockAutomaticallyOnThisMacIsOff() { app.encryption.forgetOnDevice() }
}

// MARK: - When

extension When {
    func lookForEncryptionControls() -> EncryptionControls {
        let inBuild = app.appModel.featureRegistry.contains(id: AtRestEncryptionFeatureModule.id)
        return EncryptionControls(
            offered: SettingsAvailability.encryptionOffered(
                isEnabled: app.encryption.isEnabled, moduleInBuild: inBuild))
    }

    func typePassphrase(_ typed: String) -> TypedPassphrase {
        var refused = false
        if !PassphraseStrength.meetsRequirement(typed) {
            do {
                try app.encryption.enable(passphrase: typed, iterations: EncryptionFixtures.iterations)
            } catch let error as EncryptionManager.ManagerError {
                refused = error == .passphraseTooShort
            } catch {}
        }
        return TypedPassphrase(
            canContinue: PassphraseStrength.meetsRequirement(typed),
            rating: PassphraseStrength.evaluate(typed).strength,
            turnOnRefused: refused)
    }

    func reachTheRecoveryKeyStep() throws -> RecoveryKeyStep {
        let key = RecoveryKey.generate()
        let board = NSPasteboard(name: .init("aletheia-encrypt-\(UUID().uuidString)"))
        RecoveryKeyDocument.copy(key, to: board)

        let dataRoot = app.root
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("aletheia-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let markdown = RecoveryKeyDocument.markdown(
            key: key, folderName: dataRoot.lastPathComponent, created: app.clock.now, replacesPrevious: false)
        let pdf = try XCTUnwrap(
            NotePDF.render(markdown: markdown, title: RecoveryKeyDocument.title, subtitle: RecoveryKeyDocument.subtitle),
            "could not render the recovery key PDF")
        let inside = RecoveryKeyDocument.write(
            pdf, to: dataRoot.appendingPathComponent(RecoveryKeyDocument.suggestedFileName),
            dataRoot: dataRoot, verdict: { _ in .ok })
        let outside = RecoveryKeyDocument.write(
            pdf, to: elsewhere.appendingPathComponent(RecoveryKeyDocument.suggestedFileName),
            dataRoot: dataRoot, verdict: { _ in .ok })
        let words = key.split(separator: " ").map(String.init)
        return RecoveryKeyStep(
            words: words, isAValidKey: (try? RecoveryKey.entropy(from: key)) != nil,
            clipboard: NamedClipboard(pasteboard: board),
            savedInsideDataFolder: inside, savedElsewhere: outside)
    }

    func turnOnEncryption() throws {
        try app.encryption.enable(
            passphrase: EncryptionFixtures.passphrase, recoveryKey: RecoveryKey.generate(),
            iterations: EncryptionFixtures.iterations)
    }

    func openFilesInTerminal(of seeded: SeededSession) throws -> FolderInTerminal {
        let store = try XCTUnwrap(app.appModel.store)
        return FolderInTerminal(
            probe: app.probe, secret: seeded.secret,
            patientFolder: store.patientDir(for: seeded.patient).lastPathComponent,
            sessionFolder: seeded.session.folderName)
    }

    func reopen() -> ReopenedFolder {
        app.relaunch(tier: app.tier)
        return ReopenedFolder(app: app)
    }

    func enterPassphrase(_ typed: String, in folder: ReopenedFolder) {
        try? folder.app.encryption.unlock(passphrase: typed)
    }

    func enterWrongPassphrase(times: Int) -> UnlockAttempts {
        var messages: [String] = []
        for attempt in 0..<times {
            do {
                try app.encryption.unlock(passphrase: "not the passphrase \(attempt)")
            } catch {
                messages.append(error.localizedDescription)
            }
        }
        var refused: String?
        do {
            try app.encryption.unlock(passphrase: EncryptionFixtures.passphrase)
        } catch {
            refused = error.localizedDescription
        }
        return UnlockAttempts(
            messages: messages, retryDelay: app.encryption.unlockRetryDelay,
            correctOneRefusedDuringWait: refused)
    }

    func changePassphrase(to new: String, recoveryKey: String, seeded: SeededSession) throws -> ChangedPassphrase {
        let manager = app.encryption
        let wrongRefused: Bool
        do {
            try manager.changePassphrase(
                current: "not the passphrase", new: new, iterations: EncryptionFixtures.iterations)
            wrongRefused = false
        } catch {
            wrongRefused = true
        }
        try manager.changePassphrase(
            current: EncryptionFixtures.passphrase, new: new, iterations: EncryptionFixtures.iterations)

        manager.lock()
        let oldOpens = (try? manager.unlock(passphrase: EncryptionFixtures.passphrase)) != nil
        let newOpens = (try? manager.unlock(passphrase: new)) != nil
        manager.lock()
        let recoveryOpens = (try? manager.unlock(recoveryKey: recoveryKey)) != nil
        let store = try XCTUnwrap(app.appModel.store)
        let transcript = store.transcript(for: seeded.patient, session: seeded.session)
        return ChangedPassphrase(
            wrongCurrentRefused: wrongRefused, oldOpens: oldOpens, newOpens: newOpens,
            recoveryKeyOpens: recoveryOpens,
            secretStillReadable: transcript?.contains(seeded.secret) == true)
    }

    func turnOffEncryption(seeded: SeededSession) throws -> EncryptionTurnedOff {
        let store = try XCTUnwrap(app.appModel.store)
        let transcriptURL = store.sessionDir(for: seeded.patient, session: seeded.session)
            .appendingPathComponent("transcript.txt")
        let sealed = try Data(contentsOf: transcriptURL)
        var damaged = sealed
        damaged[damaged.count - 1] ^= 0xFF
        try damaged.write(to: transcriptURL)

        var refused = false
        do { try app.encryption.disable() } catch { refused = true }
        let keystoreKept = Keystore.exists(at: app.root)
        let stillEncrypted = app.encryption.isEnabled

        try sealed.write(to: transcriptURL)
        try app.encryption.disable()
        return EncryptionTurnedOff(
            refusedWithUnreadableFile: refused, keyKeptWhileFileUnreadable: keystoreKept,
            stillEncryptedWhileFileUnreadable: stillEncrypted,
            secretReadableOnDisk: app.probe.containsPlaintext(seeded.secret),
            keystoreRemoved: !Keystore.exists(at: app.root),
            noLongerEncrypted: !app.encryption.isEnabled)
    }

    /// Records for a while, the folder locks, then the recording is stopped.
    func stopRecordingAfterTheFolderLocked(of seeded: SeededSession) async throws -> RecordingStoppedWhileLocked {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("aletheia-staging-\(UUID().uuidString)", isDirectory: true)
        let transcriptionStarted = Box(false)
        let store = try XCTUnwrap(app.appModel.store)
        let sessionFolder = store.sessionDir(for: seeded.patient, session: seeded.session)
        let micURL = store.micRecordingURL(for: seeded.patient, session: seeded.session)
        try? FileManager.default.removeItem(at: micURL)
        let callURL = store.callRecordingURL(for: seeded.patient, session: seeded.session)

        let audio = Data("live audio".utf8)
        let recorder = SessionRecorder(stagingDirectoryURL: stagingRoot)
        recorder.audioCaptureStartOverride = { mic, _ in try audio.write(to: mic) }
        recorder.onStopped = { _ in transcriptionStarted.value = true }
        let context = SessionRecorder.ActiveRecording(
            sessionID: seeded.session.id, patientID: seeded.patient.id, patientName: seeded.patient.name,
            patientSlug: "jane-doe", sessionFolder: seeded.session.folderName)
        _ = await recorder.start(
            micURL: micURL, callURL: callURL, context: context, protector: app.encryption.protector)

        app.encryption.lock()
        await recorder.stop()

        var failed = false
        if case .error = recorder.state { failed = true }
        return RecordingStoppedWhileLocked(
            probe: app.probe, sessionFolder: sessionFolder,
            stagedAudio: Store.stagingDir(for: seeded.session.id, in: stagingRoot).appendingPathComponent("mic.caf"),
            originalAudio: audio, stagingRoot: stagingRoot, seeded: seeded, transcriptionStarted: transcriptionStarted.value,
            recorderFailedVisibly: failed)
    }

    func reopenAndEnterThePassphrase(after stopped: RecordingStoppedWhileLocked) throws -> ReopenedStaging {
        let seeded = stopped.seeded
        let stagingRoot = stopped.stagingRoot
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        app.relaunch(tier: app.tier)
        try app.encryption.unlock(passphrase: EncryptionFixtures.passphrase)
        let store = try XCTUnwrap(app.appModel.store)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("aletheia-scratch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let result = OrphanAudioSweep.sweep(
            store: store, protector: app.appModel.currentProtector, audit: app.appModel.audit,
            stagingRoot: stagingRoot, scratchRoot: scratch, temporaryDirectory: scratch)
        let mic = store.micRecordingURL(for: seeded.patient, session: seeded.session)
        let readable = (try? store.readableRecording(at: mic)).flatMap { copy -> Data? in
            defer { if copy.isTemporary { try? FileManager.default.removeItem(at: copy.url) } }
            return try? Data(contentsOf: copy.url)
        }
        let staged = Store.stagingDir(for: seeded.session.id, in: stagingRoot).appendingPathComponent("mic.caf")
        return ReopenedStaging(
            recovered: result.stagedSessionsRecovered,
            audioInSessionFolder: FileManager.default.fileExists(atPath: mic.path),
            readsBack: readable == Data("live audio".utf8),
            stagedLeft: FileManager.default.fileExists(atPath: staged.path))
    }
}

/// A value a closure can set.
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Then

extension Then where Subject == EncryptionControls {
    func offersNone() { expect(!subject.offered, "expected no encryption controls in this build") }
    func offersEncryption() { expect(subject.offered, "expected encryption controls in this build") }
}

extension Then where Subject == TypedPassphrase {
    func keepsContinueDisabled() {
        expect(!subject.canContinue, "expected Continue to be disabled for a passphrase under 12 characters")
        expect(subject.turnOnRefused, "expected turning on to be refused for a passphrase under 12 characters")
    }

    func readsWeak() { expect(subject.rating == .weak, "expected the meter to read Weak, found \(subject.rating)") }
}

extension Then where Subject == RecoveryKeyStep {
    func shows24Words() {
        expectEqual(subject.words.count, 24, "recovery key words")
        expect(subject.isAValidKey, "expected the 24 words to be a valid recovery key")
    }

    func copyWordsKeepsThemOffClipboardManagers() {
        expectEqual(subject.clipboard.pastedText, subject.words.joined(separator: " "), "the copied words")
        expect(subject.clipboard.holds(PHIPasteboard.concealed), "expected the concealed marker on the copied words")
        expect(subject.clipboard.holds(PHIPasteboard.transient), "expected the transient marker on the copied words")
    }

    func savesThePDFOutsideTheDataFolderOnly() {
        if case .saved = subject.savedElsewhere {} else {
            fail("expected the PDF to save outside the data folder, found \(subject.savedElsewhere)")
        }
        if case .failed = subject.savedInsideDataFolder {} else {
            fail("expected saving inside the data folder to be refused, found \(subject.savedInsideDataFolder)")
        }
    }
}

extension Then where Subject == FolderInTerminal {
    func showsReadableContent() {
        expect(subject.secretReadable, "expected the records to be readable before encrypting")
    }

    func showsNoReadableContent() {
        expect(!subject.secretReadable, "expected transcripts, notes and recordings to be unreadable in the data folder")
    }

    func keepsFolderNamesReadable() {
        expect(subject.folderNamesReadable, "expected patient and session folder names to stay readable")
    }
}

@MainActor
extension Then where Subject == ReopenedFolder {
    func asksForThePassphrase() {
        expectEqual(subject.cover, .passphrase, "the cover shown on reopening")
    }

    func showsNoPatients() {
        expect(subject.app.appModel.patients.isEmpty,
               "expected no patient before the passphrase, found \(subject.app.appModel.patients.map(\.name))")
    }

    func showsPatients(_ names: [String]) {
        expectEqual(subject.app.appModel.patients.map(\.name), names, "the patients after the passphrase")
        expect(subject.cover == nil, "expected no cover after the passphrase, found \(String(describing: subject.cover))")
    }
}

extension Then where Subject == UnlockAttempts {
    func saysItDidntUnlockTheData() {
        expectEqual(subject.messages.first ?? "", Copy.wrongPassphrase, "the first wrong-passphrase message")
    }

    func addsAWait() {
        expect(subject.retryDelay > 0, "expected a wait after repeated failures, found \(subject.retryDelay) s")
        expect((subject.correctOneRefusedDuringWait ?? "").hasPrefix(Copy.tooManyAttempts),
               "expected even the right passphrase to be held back during the wait, found \(String(describing: subject.correctOneRefusedDuringWait))")
    }
}

extension Then where Subject == ChangedPassphrase {
    func asksForTheCurrentPassphrase() { expect(subject.wrongCurrentRefused, "expected a wrong current passphrase to be refused") }
    func opensWithOnlyTheNewPassphrase() {
        expect(subject.newOpens, "expected the new passphrase to open the data")
        expect(!subject.oldOpens, "expected the old passphrase to stop working")
    }

    func keepsTheRecoveryKeyWorking() {
        expect(subject.recoveryKeyOpens, "expected the recovery key to still open the data")
        expect(subject.secretStillReadable, "expected the data to be readable after the change")
    }
}

extension Then where Subject == EncryptionTurnedOff {
    func keptTheKeyWhileAFileCouldNotBeDecrypted() {
        expect(subject.refusedWithUnreadableFile, "expected Turn Off to refuse while a file could not be decrypted")
        expect(subject.keyKeptWhileFileUnreadable, "expected the key to be kept while a file could not be decrypted")
        expect(subject.stillEncryptedWhileFileUnreadable, "expected encryption to stay on while a file could not be decrypted")
    }

    func decryptedEverythingBeforeRemovingTheKey() {
        expect(subject.secretReadableOnDisk, "expected files to be readable once encryption is off")
        expect(subject.keystoreRemoved, "expected the key to be removed once everything is decrypted")
        expect(subject.noLongerEncrypted, "expected encryption to be off")
    }
}

extension Then where Subject == RecordingStoppedWhileLocked {
    func keepsTheAudioOutOfTheSessionFolder() {
        let caf = subject.probe.files().filter { $0.hasSuffix(".caf") }
        expect(caf.isEmpty, "expected no recording in the session folder, found \(caf)")
        expect((try? Data(contentsOf: subject.stagedAudio)) == subject.originalAudio,
               "expected the audio to stay safely in staging")
        expect(subject.recorderFailedVisibly, "expected the stop to be reported, not silent")
    }

    func doesNotStartTranscription() {
        expect(!subject.transcriptionStarted, "expected transcription not to start for audio that could not be saved")
    }
}

extension Then where Subject == ReopenedStaging {
    func addsTheAudioToTheSession() {
        expectEqual(subject.recovered, 1, "recordings recovered on reopening")
        expect(subject.audioInSessionFolder, "expected the recording in the session folder after reopening")
        expect(subject.readsBack, "expected the recovered recording to play back")
        expect(!subject.stagedLeft, "expected nothing left in staging")
    }
}
