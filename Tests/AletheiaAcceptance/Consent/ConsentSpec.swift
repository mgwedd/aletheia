@testable import Aletheia
import XCTest

final class ConsentSpec: AcceptanceCase {
    private var bench: RecordingBench!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        bench = try given.recordingBench()
    }

    override func tearDown() async throws {
        bench?.cleanUp()
        bench = nil
        try await super.tearDown()
    }

    func test_CONSENT_01() async throws {
        let (jane, _) = try await given.janeAndAdamWithSessions()

        let gate = await when.pressRecordSession(jane, on: bench)
        let sheet = try XCTUnwrap(then(gate).showsTheSheet())

        then(sheet).asksWhoHowAndWhen()
        then(sheet).confirmsWith(Copy.consentStartRecording)
        then(sheet).cannotConfirm()
        sheet.choose(.guardian)
        sheet.tickConfirmation()
        then(sheet).asksForAName()
        then(sheet).cannotConfirm()
        sheet.typeName("Sam Doe")
        then(sheet).canConfirm()
        then(bench.recorder.isRecording).expect(!bench.recorder.isRecording, "recording started before consent")
    }

    func test_CONSENT_02() async throws {
        let (jane, _) = try await given.janeAndAdamWithSessions()
        let gate = await when.pressRecordSession(jane, on: bench)
        let sheet = try XCTUnwrap(then(gate).showsTheSheet())

        sheet.choose(.patient)
        sheet.choose(.verbal)
        sheet.tickConfirmation()
        _ = try await when.confirm(sheet, on: bench)

        then(bench).isRecording(jane)
        let line = try when.consentLine(of: jane)
        then(line).says(Copy.consentFromPatientVerbally)
        then(line).showsDateAndTime(of: sheet.capture.consentedAt)
    }

    func test_CONSENT_03() async throws {
        let (jane, _) = try await given.janeAndAdamWithSessions()
        let first = try given.consentRecorded(for: jane)
        let second = try given.anotherSession(for: jane)

        let gate = await when.pressRecordSession(second, on: bench)
        then(gate).asksNothing()

        then(bench).isRecording(second)
        let line = try when.consentLine(of: second)
        then(line).says(Copy.consentOnFileSince)
        then(line).showsDate(of: first.consentedAt)
    }

    func test_CONSENT_04() async throws {
        given.activityLogIsOn()
        let (jane, adam) = try await given.janeAndAdamWithSessions()
        try given.consentRecorded(for: jane)
        try given.consentRecorded(for: adam)

        when.setRecordingConsentDefault(.everySession)

        for visit in [try given.anotherSession(for: jane), try given.anotherSession(for: adam)] {
            let gate = await when.pressRecordSession(visit, on: bench)
            let sheet = try XCTUnwrap(then(gate).showsTheSheet())
            then(sheet).explains("every session")
        }
        let entries = try when.activityLog().compactMap(\.detail)
        then(entries.joined(separator: "\n")).says("Recording consent: every session")
    }

    func test_CONSENT_05() async throws {
        let (jane, _) = try await given.janeAndAdamWithSessions()

        let gate = when.pressImportAudio(jane)

        then(gate).openedNoPicker()
        let sheet = try XCTUnwrap(then(gate).showsTheSheet())
        then(sheet).asksWhoHowAndWhen()
        then(sheet).confirmsWith(Copy.consentChooseAudio)
        let unticked = try await when.confirm(sheet)
        then(unticked).openedNoPicker()
        sheet.tickConfirmation()
        let ticked = try await when.confirm(sheet)
        then(ticked).openedThePicker()
    }

    func test_CONSENT_06() async throws {
        let (jane, _) = try await given.janeAndAdamWithSessions()

        let panel = when.chooseInMenuBar(jane.patient)

        then(panel).asksInPlace()
        then(panel).cannotStart()
        let refused = try await when.startRecording(from: panel, on: bench)
        then(refused).refusedWithoutASession(Copy.consentNotConfirmed)
        panel.capture.confirmed = true
        then(panel).canStart()
        let start = try await when.startRecording(from: panel, on: bench)
        let session = try XCTUnwrap(start.session, "no session started")
        then(bench).isRecording(session)
        then(try when.consentLine(of: PatientSession(patient: jane.patient, session: session))).says(Copy.consentFromPatientVerbally)
    }

    func test_CONSENT_07() async throws {
        let (jane, adam) = try await given.janeAndAdamWithSessions()
        try given.consentRecorded(for: jane)
        try given.consentRecorded(for: adam)

        let editor = try when.editProfile(of: jane.patient)
        then(editor.recordingConsentChoices).expectEqual(editor.recordingConsentChoices, Copy.consentPolicyChoices, "the profile's consent choices")
        editor.setRecordingConsent(.everySession)
        editor.save()

        then(when.profileConsentChoice(of: jane.patient)).expectEqual(when.profileConsentChoice(of: jane.patient), .everySession, "Jane's policy")
        let janeGate = await when.pressRecordSession(try given.anotherSession(for: jane), on: bench)
        if let sheet = then(janeGate).showsTheSheet() {
            then(sheet).explains("every session")
        }
        let adamAgain = try given.anotherSession(for: adam)
        let adamGate = await when.pressRecordSession(adamAgain, on: bench)
        then(adamGate).asksNothing()
    }

    func test_CONSENT_08() async throws {
        let (jane, adam) = try await given.janeAndAdamWithSessions()
        let sheet = when.openApplyToPatients()

        then(sheet).offers(Copy.consentPolicyChoices)
        then(sheet).cannotApply()
        sheet.select(jane.patient)
        sheet.select(adam.patient)
        then(sheet).canApply()
        sheet.choose(.everySession)
        when.apply(sheet)
        for visit in [jane, adam] {
            then(when.profileConsentChoice(of: visit.patient)).expectEqual(
                when.profileConsentChoice(of: visit.patient), .everySession, "\(visit.patient.name)'s policy")
        }

        let clear = when.openApplyToPatients()
        clear.selectAll()
        clear.choose(.useDefault)
        when.apply(clear)
        for visit in [jane, adam] {
            then(when.profileConsentChoice(of: visit.patient)).expectEqual(
                when.profileConsentChoice(of: visit.patient), .useDefault, "\(visit.patient.name)'s policy after Use default")
        }
    }

    func test_CONSENT_09() async throws {
        given.activityLogIsOn()
        let (jane, _) = try await given.janeAndAdamWithSessions()

        try given.consentRecorded(for: jane, method: .written)

        then(try when.activityLog()).attestsConsent(for: jane, method: .written)
    }

    func test_CONSENT_10() async throws {
        let (jane, _) = try await given.janeAndAdamWithSessions()
        let record = try given.consentRecorded(for: jane)

        then(try when.exportSession(jane)).eachHasConsentSection(record)
        then(try when.exportAllRecords(consentOf: jane)).hasConsentSection(record)
    }

    func test_CONSENT_11() async throws {
        let (jane, _) = try await given.janeAndAdamWithSessions()
        try given.consentRecorded(for: jane)

        let signed = try given.signedNote(in: jane)

        then(when.canChangeConsent(signed)).expect(!when.canChangeConsent(signed), "consent can still be changed after signing")
        then(try when.saveConsentAgain(signed)).wasRefusedAndKept()
    }

    func test_CONSENT_12() async throws {
        given.buildIs(.dev)
        let (jane, _) = try await given.janeAndAdamWithSessions()
        _ = try given.encryptionOn()

        let written = try given.consentRecorded(for: jane)

        then(try when.quitAndReopen(reading: written, of: jane)).isSealedAndReadsBack()
    }

    func test_CONSENT_13() async throws {
        try pending("layout: checked by the UI test test_CONSENT_13, as wrapping needs the header on screen")
    }
}
