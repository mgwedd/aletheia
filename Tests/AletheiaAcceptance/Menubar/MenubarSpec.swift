import XCTest

final class MenubarSpec: AcceptanceCase {
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

    func test_MENUBAR_01() async throws {
        let jane = try await given.patient(named: "Jane Doe")

        then(when.menuBarIcon(on: bench)).isTheSymbol("waveform")
        _ = try await when.startFromMenuBar(jane, on: bench)
        then(when.menuBarIcon(on: bench)).isTheSymbol("record.circle.fill")
        when.pauseFromMenuBar(on: bench)
        then(when.menuBarIcon(on: bench)).isTheSymbol("pause.circle.fill")
    }

    func test_MENUBAR_02() async throws {
        _ = try await given.patient(named: "Jane Doe")

        then(when.openMenuBarPanel(on: bench)).showsNotRecordingWithPickerAndStart()
    }

    func test_MENUBAR_03() async throws {
        // Partial: session creation and recording start. The main window
        // coming forward needs a UI driver.
        let jane = try await given.patient(named: "Jane Doe")

        let start = try await when.startFromMenuBar(jane, on: bench)

        then(start).createdASessionAndIsRecording(bench)
    }

    func test_MENUBAR_04() async throws {
        // Partial: the patient line and the recording state. The chip, timer
        // and level bars are drawn by RecordingMenuBar.
        let jane = try await given.patient(named: "Jane Doe")
        _ = try await when.startFromMenuBar(jane, on: bench)

        then(when.menuBarPatientLabel(for: jane)).readsAsInitials("J.D.")
    }

    func test_MENUBAR_05() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        _ = try await when.startFromMenuBar(jane, on: bench)

        when.pause(on: bench)

        then(bench).isPaused()
    }

    func test_MENUBAR_06() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let start = try await when.startFromMenuBar(jane, on: bench)
        let session = try XCTUnwrap(start.session)

        await when.stop(on: bench)

        then(bench).isSavedAndIdle(when.files(of: session, patient: jane, bench: bench))
    }

    func test_MENUBAR_07() async throws {
        // Partial: no patients to choose from. The sentence is drawn by RecordingMenuBar.
        try await given.patient(named: "Jane Doe")

        try when.deleteEveryPatient()

        then(when.patientsOfferedInPanel()).areNone()
    }

    func test_MENUBAR_08() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        given.fileVaultIsOff()

        let start = try await when.startFromMenuBar(jane, on: bench)

        then(start).createdNothingAndExplains("FileVault")
        then(bench).isNotRecording()
    }

    func test_MENUBAR_09() async throws {
        _ = try await given.patient(named: "Jane Doe")

        then(when.openMenuBarPanel(on: bench, locked: true)).showsOnlyLockedAndUnlock()
    }

    func test_MENUBAR_10() async throws {
        let window = when.openKeyboardShortcuts()

        then(window).listsGroups(3)
        then(when.shortcut(titled: "Keyboard shortcuts")).isBound(to: "⌘/")
    }

    func test_MENUBAR_11() async throws {
        // Partial: the bindings. Pressing the keys in their places needs a UI driver.
        then(when.shortcut(titled: "Add Patient")).isBound(to: "⌘N")
        then(when.shortcut(titled: "Generate or regenerate the note")).isBound(to: "⌘G")
        then(when.shortcut(titled: "Close a sheet or search")).isBound(to: "⎋")
    }

    func test_MENUBAR_12() async throws {
        // Partial: the page the item opens. Choosing Help > Report a Bug needs a UI driver.
        let page = when.chooseReportABug()

        then(page).isTheBugReportPage()
        then(page).carriesNoPatientInformation()
    }

    func test_MENUBAR_13() async throws {
        // Partial: the two-second rest. Showing the popover once needs TipKit
        // and a UI driver.
        let rest = when.restPointerOnAHelpTip()

        then(rest).showsNothingAfter(seconds: 1.9)
        then(rest).showsTheTipAfter(seconds: 2)
        then(rest).showsNothingOnceThePointerLeaves()
    }

    func test_MENUBAR_14() async throws {
        // Partial: interrupted work is saved and running jobs wind down. That
        // no alert appears needs a UI driver.
        let visit = try await given.aPatientWithASession()

        let outcome = await when.quit(whileTranscribing: visit)

        then(outcome).savedInterruptedWork(whileTranscribing: visit)
    }

    func test_MENUBAR_15() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        let first = try await when.startFromMenuBar(jane, on: bench)

        let second = try await when.startFromMenuBar(jane, on: bench)

        then(second).offeredNoSecondRecording(whileRecording: first, bench)
    }
}
