import XCTest

final class NoteSpec: AcceptanceCase {
    func test_NOTE_01() async throws {
        try pending("not automated yet")
    }

    func test_NOTE_02() async throws {
        try pending("not automated yet")
    }

    func test_NOTE_03() async throws {
        try pending("not automated yet")
    }

    func test_NOTE_04() async throws {
        try pending("not automated yet")
    }

    func test_NOTE_05() async throws {
        try pending("not automated yet")
    }

    func test_NOTE_06() async throws {
        // Clicking anywhere on the button, not only its icon, is layout: checked by the UI test.
        let desk = given.assistantDesk()
        let session = try desk.session(of: try await given.patient(named: "Jane Doe"), saying: [.you("Hello."), .client("Hi.")])

        let menu = desk.notesTab(of: session).lengthMenu

        then(menu).offersTheLengths()
        then(menu).offersAnAIEffortChoice()
    }

    func test_NOTE_07() async throws {
        try pending("not automated yet")
    }

    func test_NOTE_08() async throws {
        try pending("not automated yet")
    }

    func test_NOTE_09() async throws {
        try pending("not automated yet")
    }

    func test_NOTE_10() async throws {
        try pending("not automated yet")
    }

    func test_NOTE_11() async throws {
        try pending("not automated yet")
    }

    func test_NOTE_12() async throws {
        try pending("not automated yet")
    }

    func test_NOTE_13() async throws {
        try pending("not automated yet")
    }

    func test_NOTE_14() async throws {
        let desk = given.assistantDesk()
        let session = try desk.session(
            of: try await given.patient(named: "Jane Doe"),
            transcript: AssistantDesk.transcript(minutes: 45, about: "work"))
        desk.model.readsPromptInParts(2, thenWrites: "The client described a stressful week at work.", once: true)
        desk.model.fallback("The client described a stressful week at work.")
        let notes = desk.notesTab(of: session)

        notes.generate()
        try await notes.waitForStatus(containing: Copy.processingTranscript)
        for _ in 0..<3 { desk.model.moveOn() }
        try await notes.waitUntilIdle()

        then(notes.pane).endsWithACoverageLine()
    }

    func test_NOTE_15() async throws {
        try pending("not automated yet")
    }

    func test_NOTE_16() async throws {
        try pending("not automated yet")
    }

    func test_NOTE_17() async throws {
        let desk = given.assistantDesk()
        let session = try desk.session(
            of: try await given.patient(named: "Jane Doe"),
            transcript: AssistantDesk.transcript(minutes: 45, about: "work"))
        desk.model.fallback("The client described a stressful week at work.")
        desk.model.choosesToReadClosely()
        let notes = desk.notesTab(of: session)

        try await notes.generate(.detailed, at: .normal)
        then(notes.pane).countsFollowUpLookups()

        try await notes.generate(.natural, at: .focus)
        then(notes.pane).countsFollowUpLookups()

        try await notes.generate(.detailed, at: .fast)
        then(notes.pane).countsNoFollowUpLookups()

        try await notes.generate(.concise, at: .normal)
        then(notes.pane).countsNoFollowUpLookups()

        try await notes.generate(.natural, at: .normal)
        then(notes.pane).countsNoFollowUpLookups()
    }
}
