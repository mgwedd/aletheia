import XCTest

final class ChatSpec: AcceptanceCase {
    func test_CHAT_01() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_02() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_03() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_04() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_05() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_06() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_07() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_08() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_09() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_10() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_11() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_12() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_13() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_14() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_15() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_16() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_17() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_18() async throws {
        try pending("not automated yet")
    }

    func test_CHAT_19() async throws {
        let desk = given.assistantDesk()
        let session = try desk.session(of: try await given.patient(named: "Jane Doe"), saying: [.you("Hello."), .client("Hi.")])
        let line = "Jane worries about her mother's health."
        desk.writeInMyNotes(line, for: session)
        let ask = desk.askTab(of: session)

        ask.ask("What have I noted about Jane?")

        then(ask.pane).answeredAtOnce(quoting: line)
        then(ask.pane).saysTheAINeverReadsMyNotes()
        then(desk.model).wasNeverAsked()
    }

    func test_CHAT_20() async throws {
        let desk = given.assistantDesk()
        let session = try desk.session(
            of: try await given.patient(named: "Jane Doe"),
            transcript: AssistantDesk.transcript(minutes: 45, about: "sleep"))
        desk.model.readsPromptInParts(3, thenWrites: "She is sleeping a little better.")
        let ask = desk.askTab(of: session)

        ask.ask("What was said about sleep?")
        for part in 1...3 {
            try await ask.waitForStatus(startingWith: part < 3 ? Copy.readingPart(part, of: 3) : Copy.analyzing)
            then(ask.pane).hasNoAnswerYet()
            desk.model.moveOn()
        }
        try await ask.waitForStatus(startingWith: Copy.preparingTheAnswer)
        then(ask.pane).hasNoAnswerYet()
        desk.model.moveOn()
        try await ask.waitUntilIdle()

        then(ask.pane).showsAnswer("She is sleeping a little better.")
    }

    func test_CHAT_21() async throws {
        // That Compact sits on the effort bar, and the notice at the bottom left, is layout: checked by the UI test.
        let desk = given.assistantDesk()
        let session = try desk.session(of: try await given.patient(named: "Jane Doe"), saying: [.you("Hello."), .client("Hi.")])
        let ask = desk.askTab(of: session)
        ask.ask("How are things?")
        try await ask.waitUntilIdle()

        then(ask.pane).offersCompact()
        then(ask.pane).showsTheAccuracyNotice()
    }

    func test_CHAT_22() async throws {
        let desk = given.assistantDesk()
        let session = try desk.session(
            of: try await given.patient(named: "Jane Doe"),
            transcript: AssistantDesk.transcript(minutes: 45, about: "sleep"))
        desk.model.summarizesConversation(as: "Earlier: sleep was discussed.")
        desk.model.answersPastAQuarterOfTheWindow()
        let ask = desk.askTab(of: session)

        ask.ask("What was said about sleep?")
        try await ask.waitUntilIdle()
        then(ask.pane).hasNotCompacted()

        ask.ask("And about work?")
        try await ask.waitUntilIdle()

        then(ask.pane).compactedBefore(answering: "And about work?")
    }
}
