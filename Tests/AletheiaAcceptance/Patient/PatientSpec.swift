import XCTest

final class PatientSpec: AcceptanceCase {
    func test_PATIENT_01() async throws {
        try pending("UI driver: empty-state text and the Add Patient button")
    }

    func test_PATIENT_02() async throws {
        then(when.typeIntoNewPatientSheet("")).addIsDisabled()
        then(when.typeIntoNewPatientSheet("   ")).addIsDisabled()
        then(when.typeIntoNewPatientSheet("Jane Doe")).addIsEnabled()

        let attempt = try await when.addPatient(named: "   ")

        then(attempt).addedNobody()
    }

    func test_PATIENT_03() async throws {
        let attempt = try await when.addPatient(named: "Jane Doe")
        then(attempt).addedPatient(named: "Jane Doe")

        let page = try when.openPage(of: attempt.patient!)

        then(page).showsName("Jane Doe")
        then(page).showsNoSessions()
    }

    func test_PATIENT_04() async throws {
        try await given.patient(named: "Joanne Fox")
        try await given.patient(named: "adam lee")

        let sidebar = when.lookAtSidebar()

        then(sidebar).listsPatients(inOrder: ["adam lee", "Joanne Fox"])
        then(sidebar).showsInitials(["AL", "JF"])
        then(sidebar).showsAddedDates(in: app.clock.now)
    }

    func test_PATIENT_05() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let editor = try when.editProfile(of: jane)

        editor.setName("   Jane    Q   Doe  ")
        editor.save()
        then(try when.readStoredPatient(jane)).isNamed("Jane Q Doe")

        let blank = try when.editProfile(of: jane)
        blank.setName("   ")
        blank.save()
        then(blank).cannotSave(because: Copy.nameRequired)
        then(try when.readStoredPatient(jane)).isNamed("Jane Q Doe")
    }

    func test_PATIENT_06() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let editor = try when.editProfile(of: jane)
        editor.setClinicalHistory("Generalised anxiety, 2019")
        editor.setNotes("Prefers morning sessions")
        editor.save()

        then(try when.openPage(of: jane)).profileShowsOnly(["Clinical history", "Notes"])

        let notesOnly = try when.editProfile(of: jane)
        notesOnly.setClinicalHistory("")
        notesOnly.save()
        then(try when.openPage(of: jane)).profileShowsOnly(["Notes"])

        let empty = try when.editProfile(of: jane)
        empty.setNotes("")
        empty.save()
        then(try when.openPage(of: jane)).profileSaysNothingRecorded()
    }

    func test_PATIENT_07() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let editor = try when.editProfile(of: jane)
        then(editor.cancel()).closesWithoutAsking()

        editor.setNotes("A change I may not keep")
        then(editor.cancel()).asksToDiscard()
        then(try when.readStoredPatient(jane)).hasNotes("")
    }

    func test_PATIENT_08() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let other = try await given.patient(named: "John Roe")
        try await given.sessions(2, for: jane)
        let folder = try given.folder(of: jane)
        then(folder).exists()

        then(try when.askToDeletePatient(jane, typing: "Jan")).deleteIsDisabled()
        then(try when.askToDeletePatient(jane, typing: "")).deleteIsDisabled()
        let confirmation = try when.askToDeletePatient(jane, typing: "  jane doe ")
        then(confirmation).namesTheCopiesThatRemain()
        then(confirmation).deleteIsEnabled()
        try confirmation.confirm()

        then(folder).isGone()
        then(when.lookAtSidebar()).listsPatients(inOrder: ["John Roe"])
        then(try given.folder(of: other)).exists()
    }

    func test_PATIENT_09() async throws {
        given.fileVaultIsOff()

        let attempt = try await when.addPatient(named: "Jane Doe")

        then(attempt).wasBlockedByFileVault()
        then(when.lookAtSidebar()).isEmpty()
    }

    func test_PATIENT_10() async throws {
        given.buildIs(.dev)
        let jane = try await given.patient(named: "Jane Doe")
        let editor = try when.editProfile(of: jane)

        editor.addMedication()
        editor.addMedication()
        then(editor).hasMedicationRows(2)

        editor.removeMedication(at: 0)
        then(editor).hasMedicationRows(1)

        editor.removeMedication(at: 0)
        then(editor).hasMedicationRows(0)
        then(editor).readsNoMedications()
    }

    func test_PATIENT_11() async throws {
        given.buildIs(.dev)
        let jane = try await given.patient(named: "Jane Doe")
        let editor = try when.editProfile(of: jane)
        editor.addMedication()
        editor.addMedication()
        editor.addMedication()
        editor.fillMedication(at: 0, name: "Sertraline", dose: "50 mg")
        editor.fillMedication(at: 2, name: "Lithium", dose: "300 mg")
        editor.save()

        then(try when.readStoredPatient(jane)).hasMedications(["Sertraline 50 mg", "Lithium 300 mg"])
        then(try when.openPage(of: jane)).profileRow("Medications", reads: "Sertraline 50 mg, Lithium 300 mg")
    }

    func test_PATIENT_12() async throws {
        given.buildIs(.dev)
        let jane = try await given.patient(named: "Jane Doe")
        try await given.profile(of: jane, medications: [("Sertraline", "50 mg")])

        given.buildIs(.release)
        let editor = try when.editProfile(of: jane)
        then(editor).hidesMedicationsTable()
        editor.setNotes("Seen in clinic")
        editor.save()

        then(try when.readStoredPatient(jane)).hasMedications(["Sertraline 50 mg"])
        then(try when.openPage(of: jane)).profileShowsOnly(["Notes"])
    }

    func test_PATIENT_13() async throws {
        then(when.dragSidebarEdge(by: 60)).movesTheSidebarBy(60)
        then(when.dragSidebarEdge(by: -40)).movesTheSidebarBy(-40)
        then(when.dragSidebarEdge(by: 5000)).staysUsable()
        then(when.dragSidebarEdge(by: -80)).staysUsable()
        then(when.dragSidebarEdge(by: -5000)).collapsesTheSidebar()
        then(when.dragFromWindowEdge(by: 40)).leavesTheSidebarHidden()
        then(when.dragFromWindowEdge(by: 300)).bringsTheSidebarBack()
    }

    func test_PATIENT_14() async throws {
        then(when.dragSidebarEdgeAndReopen(by: 70)).reopensShowing(widenedBy: 70)
        then(when.hideSidebarAndReopen()).reopensHidden()
    }
}
