import XCTest

final class ChatSpec: AcceptanceCase {
    func test_CHAT_01() async throws {
        let desk = given.assistantDesk()
        let jane = try await given.patient(named: "Jane Doe")
        let session = try desk.session(of: jane, saying: [.you("Hello."), .client("Hi.")])

        let ask = desk.askTab(of: session)

        then(ask.pane).showsTheEmptyPrompt()
    }

    func test_CHAT_02() async throws {
        let desk = given.assistantDesk()
        let jane = try await given.patient(named: "Jane Doe")
        let session = try desk.session(of: jane, saying: [.you("Hello."), .client("Hi.")])
        desk.model.pausesOnTheFirstRequest(writing: "She is sleeping")
        let ask = desk.askTab(of: session)

        ask.ask("How is she sleeping?")
        try await ask.waitUntilShowing("She is sleeping")

        then(ask.pane).showsQuestionAsBubble("How is she sleeping?")
        then(ask.pane).streamsWithStop()

        desk.model.moveOn()
        try await ask.waitUntilIdle()
        then(ask.pane).showsAnswer("She is sleeping")
    }

    func test_CHAT_03() async throws {
        let desk = given.assistantDesk()
        let jane = try await given.patient(named: "Jane Doe")
        let session = try desk.session(of: jane, saying: [.you("Hello."), .client("Hi.")])
        desk.model.fallback("She is sleeping a little better.")
        let ask = desk.askTab(of: session)

        ask.ask("How is she sleeping?")
        try await ask.waitUntilIdle()

        then(ask.pane).showsReadLine()
    }

    func test_CHAT_04() async throws {
        let desk = given.assistantDesk()
        let jane = try await given.patient(named: "Jane Doe")
        let session = try desk.session(of: jane, saying: [.you("Hello."), .client("Hi.")])
        desk.model.pausesOnTheFirstRequest(writing: "She is sleeping")
        let ask = desk.askTab(of: session)
        ask.ask("How is she sleeping?")
        try await ask.waitUntilShowing("She is sleeping")

        ask.stop()
        try await ask.waitUntilIdle()

        then(ask.pane).keepsAnswerSoFar("She is sleeping")
    }

    func test_CHAT_05() async throws {
        let desk = given.assistantDesk()
        let jane = try await given.patient(named: "Jane Doe")
        let session = try desk.session(of: jane, saying: [.you("Hello."), .client("Hi.")])
        desk.model.pausesOnTheFirstRequest(writing: "Noted.")
        let notes = desk.notesTab(of: session)
        notes.generate()
        try await notes.waitUntilWriting()
        let ask = desk.askTab(of: session)

        ask.ask("How are things?")
        then(ask.pane).isWaitingWithCancel()

        ask.cancelWaiting()
        then(ask.pane).doesNotShowQuestion("How are things?")

        desk.model.release()
        try await notes.waitUntilIdle()
    }

    func test_CHAT_06() async throws {
        let desk = given.assistantDesk()
        let jane = try await given.patient(named: "Jane Doe")
        let session = try desk.session(of: jane, saying: [.you("Hello."), .client("Hi.")])
        desk.model.fallback("She said it was poor.")
        let ask = desk.askTab(of: session)
        ask.ask("What did she say about sleep?")
        try await ask.waitUntilIdle()

        given.appRelaunched()

        let reopened = given.assistantDesk(model: desk.model).askTab(of: session)
        then(reopened.pane).showsEarlierExchange(question: "What did she say about sleep?", answer: "She said it was poor.")
    }

    func test_CHAT_07() async throws {
        try pending("the dictation draft lives in the composer's view state and the speech engine is a system service; no fake is wired into the Ask tab")
    }

    func test_CHAT_08() async throws {
        try pending("opening the Ask about window is a view action with no seam in the acceptance layer")
    }

    func test_CHAT_09() async throws {
        let desk = given.assistantDesk()
        let jane = try await given.patient(named: "Jane Doe")
        _ = try desk.session(of: jane, saying: [.you("Hello."), .client("Hi.")])
        let chat = desk.patientChat(of: jane)

        for question in ["First question?", "Second question?", "Third question?"] {
            chat.startNewThread()
            chat.ask(question)
            try await chat.waitUntilIdle()
        }

        then(chat).listsThreadsNewestFirst(["Third question?", "Second question?", "First question?"])

        given.appRelaunched()

        let reopened = given.assistantDesk(model: desk.model).patientChat(of: jane)
        then(reopened).listsThreadsNewestFirst(["Third question?", "Second question?", "First question?"])
    }

    func test_CHAT_10() async throws {
        let desk = given.assistantDesk()
        let jane = try await given.patient(named: "Jane Doe")
        let chat = desk.patientChat(of: jane)

        try when.removePatient(jane)

        then(chat).showsPatientGone()
    }

    func test_CHAT_11() async throws {
        let desk = given.assistantDesk()
        let jane = try await given.patient(named: "Jane Doe")
        _ = try desk.session(of: jane, transcript: AssistantDesk.transcript(minutes: 10, about: "sleep"), daysAgo: 7)
        _ = try desk.session(of: jane, transcript: AssistantDesk.transcript(minutes: 10, about: "sleep"))
        desk.model.fallback("Her sleep has improved since the spring [S1].")
        let chat = desk.patientChat(of: jane)

        chat.ask("How has sleep changed across sessions?")
        try await chat.waitUntilIdle()

        then(chat.pane).citesSessionsByDateWithASourcesLine()
    }

    func test_CHAT_12() async throws {
        let desk = given.assistantDesk()
        let jane = try await given.patient(named: "Jane Doe")
        _ = try desk.session(of: jane, transcript: AssistantDesk.transcript(minutes: 10, about: "sleep"), daysAgo: 7)
        _ = try desk.session(of: jane, transcript: AssistantDesk.transcript(minutes: 10, about: "sleep"))
        desk.model.fallback("Her sleep has improved.")
        let chat = desk.patientChat(of: jane)
        chat.chooseEffort(.focus)

        chat.ask("How has sleep changed across sessions?")
        try await chat.waitUntilIdle()

        then(chat.pane).readLineNamesSessionsAndEffort(sessions: 2, .focus)
    }

    func test_CHAT_13() async throws {
        let desk = given.assistantDesk()
        let jane = try await given.patient(named: "Jane Doe")
        let session = try desk.session(of: jane, saying: [.you("Hello."), .client("Hi.")])
        desk.model.fallback("She said it was poor.")
        desk.model.summarizesConversation(as: "Earlier: sleep was poor.")
        let ask = desk.askTab(of: session)
        ask.ask("What did she say about sleep?")
        try await ask.waitUntilIdle()
        ask.ask("And about work?")
        try await ask.waitUntilIdle()

        ask.compact()
        try await ask.waitUntilIdle()

        then(ask.pane).showsCompactedCardReplacingEarlier()
    }

    func test_CHAT_14() async throws {
        try pending("the Diagram and Source toggle is drawn by the diagram view with no seam in the acceptance layer")
    }

    func test_CHAT_15() async throws {
        try pending("the code block's Copy button and its Copied feedback are view state with no seam in the acceptance layer")
    }

    func test_CHAT_16() async throws {
        let desk = given.assistantDesk()
        let jane = try await given.patient(named: "Jane Doe")
        let session = try desk.session(of: jane, saying: [.you("Hello."), .client("Hi.")])
        desk.model.hasNoModelDownloaded()
        let ask = desk.askTab(of: session)

        ask.ask("What did she say about sleep?")
        let alert = try await ask.waitForAlert()

        then(alert).isAnAIAlert()
        then(ask.pane).showsQuestionAsBubble("What did she say about sleep?")

        desk.model.clearRules()
        desk.model.fallback("She said it was poor.")
        try desk.askAgain(alert)
        try await ask.waitUntilIdle()

        then(ask.pane).showsQuestionOnlyOnce("What did she say about sleep?")
        then(ask.pane).showsAnswer("She said it was poor.")
    }

    func test_CHAT_17() async throws {
        try pending("the right-click menu of a thread in the Chats list is a view with no seam in the acceptance layer")
    }

    func test_CHAT_18() async throws {
        let desk = given.assistantDesk()
        let jane = try await given.patient(named: "Jane Doe")
        let session = try desk.session(of: jane, saying: [.you("Hello."), .client("Hi.")])

        desk.askTab(of: session).chooseEffort(.focus)
        desk.patientChat(of: jane).chooseEffort(.fast)
        desk.notesTab(of: session).chooseEffort(.fast)

        then(desk).keepsEfforts(ask: .focus, patient: .fast, notes: .fast)
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
