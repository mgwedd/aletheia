import XCTest

final class RecordSpec: AcceptanceCase {
    private var bench: RecordingBench!
    private var importing: ImportBench!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        bench = try given.recordingBench()
        importing = try given.importBench()
    }

    override func tearDown() async throws {
        bench?.cleanUp()
        bench = nil
        importing?.cleanUp()
        importing = nil
        try await super.tearDown()
    }

    func test_RECORD_01() async throws {
        // Partial: the state the red dot, timer and buttons are drawn from.
        // The pixels themselves need a UI driver.
        let visit = try await given.aPatientWithASession()

        let refusal = await when.pressRecord(on: bench, visit)

        then(refusal).isNoRefusal()
        then(bench).isRecording(visit)
    }

    func test_RECORD_02() async throws {
        let visit = try await given.aPatientWithASession()
        await when.pressRecord(on: bench, visit)
        then(bench).metersAreSilent()

        when.hearSound(on: bench, mic: 0.3, call: 0.3)
        then(bench).metersMove()
        let soft = when.readMeters(on: bench)

        when.hearSound(on: bench, mic: 0.9, call: 0.9, polls: 30)
        then(bench).metersAreLouder(than: soft)
    }

    func test_RECORD_03() async throws {
        // Partial: a second recording is refused and the first is untouched.
        // The "Recording another session" label is drawn by the session view.
        let first = try await given.aPatientWithASession()
        let second = try given.anotherSession(for: first)
        await when.pressRecord(on: bench, first)

        let refusal = await when.pressRecord(on: bench, second)

        then(bench).refusedBecauseAnotherIsRecording(refusal)
        then(bench).stillRecording(first)
    }

    func test_RECORD_04() async throws {
        let visit = try await given.aPatientWithASession()
        await when.pressRecord(on: bench, visit)

        when.pause(on: bench)
        then(bench).timerHolds()
        then(bench).isPaused()

        when.resume(on: bench)
        then(bench).isRecording(visit)
    }

    func test_RECORD_05() async throws {
        let visit = try await given.aPatientWithASession()
        await when.pressRecord(on: bench, visit)

        when.recordWithoutCallAudio(on: bench, seconds: 60)
        then(bench).doesNotWarnAboutCallAudio()

        when.recordWithoutCallAudio(on: bench, seconds: 30)
        then(bench).warnsOnlyMicrophoneIsRecorded()
    }

    func test_RECORD_06() async throws {
        // Partial: the permission prompt itself is the system's; the refusal
        // is injected at the capture start and the app's response is checked.
        let visit = try await given.aPatientWithASession()
        given.microphoneIsDenied(bench)

        let message = await when.pressRecord(on: bench, visit)

        then(bench).isNotRecording()
        then(bench).pointsToSystemSettings(message)
    }

    func test_RECORD_07() async throws {
        let visit = try await given.aPatientWithASession()
        given.fileVaultIsOff()

        await when.pressRecord(on: bench, visit)

        then(bench).isNotRecording()
        then(bench).showsTurnOnFileVaultAlert()
    }

    func test_RECORD_08() async throws {
        // The threshold is shortened from 90 minutes; the rule itself is pinned too.
        then(bench).remindsAtNinetyMinutes()
        let visit = try await given.aPatientWithASession()
        await when.recordWithReminderAfter(0.1, on: bench, visit)

        let alert = try await when.waitForStillRecordingAlert(on: bench)

        then(alert).asksWhetherYouForgot()
        when.keepRecording(on: bench)
        then(bench).stillRecording(visit)
        await when.stopNow(on: bench)
        then(bench).isNotRecording()
    }

    func test_RECORD_09() async throws {
        let visit = try await given.aPatientWithASession()
        await when.pressRecord(on: bench, visit)

        await when.stop(on: bench)

        then(bench).isNotRecording()
        then(bench).savedBothFiles(when.files(of: visit, bench: bench))
        then(bench).leftNothingStaged(for: visit)
        then(bench).startedTranscriptionOnItsOwn(for: visit)
    }

    func test_RECORD_10() async throws {
        let visit = try await given.aPatientWithASession()
        await when.pressRecord(on: bench, visit)
        then(when.files(of: visit, bench: bench)).areMissing()

        when.forceQuitAndReopen(bench)

        then(bench).recoveredOneInterruptedSession()
        let recovered = when.files(of: visit, bench: bench)
        then(recovered).hold(RecordingBench.micBytes)
        then(recovered).hold(RecordingBench.callBytes, onMic: false)
    }

    func test_RECORD_11() async throws {
        let visit = try await given.aPatientWithASession()
        await when.pressRecord(on: bench, visit)
        try when.deleteFolder(of: visit.patient, bench: bench)

        when.forceQuitAndReopen(bench)

        then(bench).setAsideOneRecording()
        let setAside = when.openSetAsideRecordings(on: bench)
        then(setAside).listsItems(1)
        then(setAside).warningDoesNotNamePatient(of: visit)
    }

    func test_RECORD_12() async throws {
        let visit = try await given.aPatientWithASession()
        await when.pressRecord(on: bench, visit)
        try when.deleteFolder(of: visit.patient, bench: bench)
        when.forceQuitAndReopen(bench)
        let setAside = when.openSetAsideRecordings(on: bench)
        let other = try await given.aPatientWithASession(named: "John Roe")

        try when.recoverFirstSetAside(setAside, into: other, bench: bench)

        let files = when.files(of: other, bench: bench)
        then(files).hold(RecordingBench.micBytes)
        then(files).hold(RecordingBench.callBytes, onMic: false)
        then(setAside).listsItems(0)
    }

    func test_RECORD_13() async throws {
        let visit = try await given.aPatientWithASession()
        await when.pressRecord(on: bench, visit)
        try when.deleteFolder(of: visit.patient, bench: bench)
        when.forceQuitAndReopen(bench)
        let setAside = when.openSetAsideRecordings(on: bench)

        let folder = try when.deleteFirstSetAside(setAside)

        then(setAside).listsItems(0)
        then(folder).isGone()
    }

    func test_RECORD_14() async throws {
        try pending("seam: the capture hook writes fixed stand-in bytes, so sound made during a pause cannot be told apart from sound after it")
    }

    func test_RECORD_15() async throws {
        // Partial: the picker and the transcription the view starts are the
        // view's own; the gates, the import and what it leaves are checked.
        let visit = try await given.aPatientWithASession()
        given.recordingConsent(of: visit)
        let file = try given.anAudioFile(importing)
        let original = try Data(contentsOf: file)
        then(importing).offersImport(for: visit)

        then(when.pressImportAudio(on: importing, visit)).opensTheFilePicker()
        when.pick(file, on: importing, into: visit)

        then(importing).hasNoFailure()
        try then(importing).becameTheRecording(of: visit)
        then(importing).leftTheOriginalAlone(file, original)
        then(importing).startsTranscriptionOnItsOwn()
        then(importing).offersNoImport(for: visit)
    }

    func test_RECORD_16() async throws {
        let visit = try await given.aPatientWithASession()

        let first = when.pressImportAudio(on: importing, visit)

        then(first).asksForConsentFirst()
        then(importing).savedNothing(for: visit)
        then(when.confirmRecordingConsent(on: importing, visit)).opensTheFilePicker()
    }

    func test_RECORD_17() async throws {
        let visit = try await given.aPatientWithASession()
        given.recordingConsent(of: visit)
        let file = try given.aFileThatIsNotAudio(importing)

        when.pick(file, on: importing, into: visit)

        then(importing).refusedAsNotAudio()
        then(importing).savedNothing(for: visit)
    }

    func test_RECORD_18() async throws {
        let visit = try await given.aPatientWithASession()
        given.recordingConsent(of: visit)
        let existing = Data("recorded in the app".utf8)
        try given.aRecording(existing, in: visit, importing)
        let file = try given.anAudioFile(importing)

        then(importing).offersNoImport(for: visit)
        when.pick(file, on: importing, into: visit)

        then(importing).refusedToReplaceTheRecording()
        then(importing).keptTheRecording(of: visit, existing)
    }

    func test_RECORD_19() async throws {
        let visit = try await given.aPatientWithASession()
        given.recordingConsent(of: visit)
        try given.aSignedNote(in: visit, importing)
        let file = try given.anAudioFile(importing)

        when.pick(file, on: importing, into: visit)

        then(importing).refusedBecauseTheNoteIsSigned()
        then(importing).savedNothing(for: visit)
    }

    func test_RECORD_20() async throws {
        let visit = try await given.aPatientWithASession()
        given.recordingConsent(of: visit)
        given.fileVaultIsOff()

        let step = when.pressImportAudio(on: importing, visit)

        then(step).isRefused()
        then(importing).showsTurnOnFileVaultAlert()
        then(importing).savedNothing(for: visit)
    }
}
