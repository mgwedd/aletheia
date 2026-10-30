import XCTest

final class ExportSpec: AcceptanceCase {
    func test_EXPORT_01() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let sam = try await given.patient(named: "Sam Lee")
        try given.exportSession(for: jane)
        try given.exportSession(for: sam)

        let run = try when.exportAllRecords()
        try await when.waitForExport(run)

        then(run).producedFolderOfPatients(["Jane Doe", "Sam Lee"])
    }

    func test_EXPORT_02() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.exportSession(for: jane)

        let run = try await when.startExportAndCancelIt()

        then(run).leftNothingBehind()
        then(run).postedNothing()
    }

    func test_EXPORT_03() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.exportSession(for: jane, notes: ["SOAP": "S: ok"], recordings: true)
        try given.exportSession(for: jane, day: 1)

        let run = try when.exportAllRecords()
        try await when.waitForExport(run)

        then(run).finishedAndNotifiedAsReady()
        let toast = when.lookAtToast(run)
        then(toast).readsCounts(patients: 1, sessions: 2)
        then(toast).countsMatchTheFilesWritten()
    }

    func test_EXPORT_04() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.exportSession(for: jane)

        let run = try when.exportAllRecords(to: .folderThatCannotBeWritten)
        try await when.waitForExport(run)

        then(run).failedWithDidntFinish()
    }

    func test_EXPORT_05() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.exportSession(for: jane)

        let run = try when.exportAllRecords(to: .iCloudDrive)
        try await when.waitForExport(run)

        then(run).refusedWithNothingWritten()
    }

    func test_EXPORT_06() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let sam = try await given.patient(named: "Sam Lee")
        try given.exportSession(for: jane, recordings: true)
        try given.exportSession(for: jane, day: 1)
        try given.exportSession(for: sam)

        let run = try when.exportAllRecords()
        try await when.waitForExport(run)

        let export = when.openExportFolder(run)
        then(export).readMeCounts(patients: 2, sessions: 3, recordings: 2)
        then(export).hasPatientFolder("Jane Doe records")
        then(export).hasSessionFolders(2, underPatient: "Jane Doe")
        then(export).hasSessionFolders(1, underPatient: "Sam Lee")
    }

    func test_EXPORT_07() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.exportSession(
            for: jane, notes: ["SOAP": "S: low mood", "DAP": "D: low mood"],
            comment: "Revisit this", recordings: true)

        let run = try when.exportAllRecords()
        try await when.waitForExport(run)

        let patientFolder = when.openPatientFolder("Jane Doe", in: when.openExportFolder(run))
        let folder = try when.openSessionFolder(in: patientFolder)
        then(folder).holds([
            Copy.exportTranscript, "Note - SOAP.txt", "Note - DAP.txt",
            "Recording - microphone.caf", "Recording - call.caf",
        ])
        then(folder).recordingsPlay()
    }

    func test_EXPORT_08() async throws {
        let acdc = try await given.patient(named: "AC/DC: Live")
        let smith = try await given.patient(named: "Smith\\Jones")
        try given.exportSession(for: acdc)
        try given.exportSession(for: smith)

        let run = try when.exportAllRecords()
        try await when.waitForExport(run)

        let export = when.openExportFolder(run)
        then(export).hasPatientFolder("AC-DC- Live records")
        then(export).hasPatientFolder("Smith-Jones records")
    }

    func test_EXPORT_09() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.exportSession(for: jane, notes: ["SOAP": "S: ok"], recordings: true)
        try given.exportSession(for: jane, day: 1)

        then(when.askToSavePatientZip(jane)).suggestsName("Jane Doe - Records.zip")
        let run = try when.exportPatientZip(jane)
        try await when.waitForExport(run)

        let zip = try when.openZip(of: run)
        then(zip).holdsOnlyTextFiles()
        then(zip).hasEntry("Jane Doe records/Read me.txt")
        then(zip).hasOneFolderPerSession(2, under: "Jane Doe records")
    }

    func test_EXPORT_10() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let note = "Client reports steady mood."
        let session = try given.exportSession(for: jane, notes: ["SOAP": note])

        then(when.openExportMenu()).offers(["PDF", "Word", "Markdown"], preselecting: "PDF")

        let pdf = try await when.exportNote(note, of: session, as: .pdf)
        then(pdf).suggestsName("Jane Doe - \(session.day) - SOAP.pdf")
        then(pdf).opensWith(["Jane Doe", note])

        let word = try await when.exportNote(note, of: session, as: .word)
        then(word).suggestsName("Jane Doe - \(session.day) - SOAP.docx")
        then(word).opensWith(["Jane Doe", note])

        let markdown = try await when.exportNote(note, of: session, as: .markdown)
        then(markdown).suggestsName("Jane Doe - \(session.day) - SOAP.md")
        then(markdown).startsWith("# Jane Doe")
        then(markdown).opensWith([note])
    }

    func test_EXPORT_11() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let session = try given.exportSession(
            for: jane, transcript: "Therapist: how was the week?", summary: "Steady week overall.")

        for type in [NoteFileType.markdown, .pdf] {
            let file = try await when.exportWholeSession(session, as: type)
            then(file).opensWith(["Jane Doe", "Summary", "Steady week overall.", "Transcript", "how was the week?"])
        }
        let markdown = try await when.exportWholeSession(session, as: .markdown)
        then(markdown).opensWith([session.longDate])
    }

    func test_EXPORT_12() async throws {
        given.fileVaultIsOff()

        let choice = try when.pickExportFolder(.anyFolderOnThisMac)

        then(choice).warnsTheDiskIsntEncrypted()
        then(choice).hasWrittenNothing()
    }

    func test_EXPORT_13() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let sam = try await given.patient(named: "Sam Lee")
        try given.exportSession(for: jane, notes: ["SOAP": "S: ok"])
        try given.exportSession(for: sam, comment: "Revisit this")

        let nothing = try when.askToExportPsychotherapyNotes(jane)
        then(nothing).saysThereIsNothingToExport()
        then(nothing).goesNoFurther()

        then(try when.askToExportPsychotherapyNotes(sam)).goesOnToConfirmAuthorization()
    }
}
