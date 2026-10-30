import XCTest

/// The Ask tab in the real app, driven with the scripted AI.
final class ChatUITests: AcceptanceCase {
    func test_CHAT_01_emptyAskTabOffersAQuestionBox() {
        given.aSessionToAskAbout()
        let tab = when.openAskTab()

        then(tab).showsText(Copy.askEmptyTitle)
        XCTAssertTrue(app.exists(tab.field), "no question box")
    }

    func test_CHAT_02_questionShowsAsBubbleAndTheAnswerStreamsWithStop() {
        given.aSessionToAskAbout(replies: ["Sleep is the main concern."], stageMs: 1500)
        let tab = when.openAskTab()

        when.ask("What did she say about insomnia?", on: tab)

        then(tab).showsText("What did she say about insomnia?")
        then(tab).showsStop()
        then(tab).showsText("Sleep is the main concern.")
    }

    func test_CHAT_03_answerCarriesAReadLine() {
        given.aSessionToAskAbout(replies: ["She said it has been poor."])
        let tab = when.openAskTab()

        when.ask("What did she say about sleep?", on: tab)

        then(tab).showsText("She said it has been poor.")
        then(tab).showsText(Copy.readLead)
    }

    func test_CHAT_06_answerIsStillThereAfterARelaunch() {
        given.aSessionToAskAbout(replies: ["She said it has been poor."])
        let tab = when.openAskTab()
        when.ask("What did she say about sleep?", on: tab)
        then(tab).showsText("She said it has been poor.")

        app.relaunch()

        then(when.openAskTab()).showsText("She said it has been poor.")
    }

    func test_CHAT_13_compactReplacesTheEarlierMessages() {
        given.aSessionToAskAbout(chat: [
            .init(role: "user", text: "What did she say about sleep?"),
            .init(role: "assistant", text: "She said it has been poor."),
        ])
        let tab = when.openAskTab()

        tab.compact.click()

        then(tab).showsText(Copy.compactedChip)
        then(tab).doesNotShowText("She said it has been poor.")
    }

    func test_CHAT_16_missingModelShowsAnAlertAndKeepsTheQuestion() {
        given.aSessionToAskAbout(modelMissing: true)
        let tab = when.openAskTab()

        when.ask("What did she say about sleep?", on: tab)

        then(tab).showsText(Copy.modelMissingTitle)
        then(tab).showsText("What did she say about sleep?")
    }

    func test_CHAT_19_askingAboutMyNotesQuotesThemAtOnce() {
        let line = "Jane is worried about the move in March."
        given.aSessionToAskAbout(myNotes: line)
        let tab = when.openAskTab()

        when.ask("What have I noted about Jane?", on: tab)

        then(tab).showsText(line)
        then(tab).showsText(Copy.myNotesHeader)
        then(app.probe).sentTheModelNothing()
    }

    func test_CHAT_20_statusMovesThroughReadingAnalyzingAndPreparing() {
        given.aSessionToAskAbout(replies: ["Sleep is the main concern."], stageMs: 1500, parts: 3)
        let tab = when.openAskTab()

        when.ask("What did she say about insomnia?", on: tab)

        then(tab).statusReads(Copy.readingTheSession)
        then(tab).statusReads(Copy.analyzing)
        then(tab).statusReads(Copy.preparingTheAnswer)
        then(tab).showsText("Sleep is the main concern.")
    }

    func test_CHAT_21_compactSitsOnTheEffortBarAndTheDisclaimerAtTheBottomLeft() {
        given.aSessionToAskAbout(chat: [
            .init(role: "user", text: "What did she say about sleep?"),
            .init(role: "assistant", text: "She said it has been poor."),
        ])
        let tab = when.openAskTab()

        XCTAssertTrue(app.exists(tab.compact), "no Compact button")
        XCTAssertTrue(app.exists(tab.disclaimer), "no accuracy notice")

        then(tab).keepsCompactOnTheEffortBar()
        then(tab).showsDisclaimerAtTheBottomLeft()
    }

    func test_CHAT_22_longConversationCompactsBeforeTheNextAnswer() {
        executionTimeAllowance = 120
        let filler = String(repeating: "We talked about sleep, work and the move. ", count: 30)
        given.aSessionToAskAbout(
            chat: (0..<5).map { .init(role: $0 % 2 == 0 ? "user" : "assistant", text: "\($0). " + filler) },
            replies: ["Earlier the conversation covered sleep, work and the move.", "She named the deadline."],
            contextTokens: 6_000)
        let tab = when.openAskTab()

        when.ask("What did she say about the deadline?", on: tab)

        then(tab).showsText(Copy.compactedChip)
        then(tab).showsText("She named the deadline.")
        then(tab).showsCompactedCardAboveTheAnswer()
    }
}

extension Then where Subject == AskTabOnScreen {
    func keepsCompactOnTheEffortBar() {
        let compact = subject.compact.frame
        let effort = subject.effortBar.frame
        expect(abs(compact.midY - effort.midY) < 24, "Compact is not level with the AI effort bar: \(compact) vs \(effort)")
        expect(compact.minX > effort.minX, "Compact is not at the trailing end of the effort bar")
    }

    func showsDisclaimerAtTheBottomLeft() {
        let notice = subject.disclaimer
        let text = notice.label.isEmpty ? (notice.value as? String ?? "") : notice.label
        expect(text == Copy.disclaimer, "the accuracy notice reads \"\(text)\"")
        let lastMessage = subject.driver.text(containing: "She said it has been poor.").frame
        expect(notice.frame.minY >= lastMessage.maxY, "the accuracy notice is not below the conversation: \(notice.frame) vs \(lastMessage)")
        expect(notice.frame.minX <= lastMessage.minX + 40, "the accuracy notice is not at the left of the conversation: \(notice.frame) vs \(lastMessage)")
    }

    func showsCompactedCardAboveTheAnswer() {
        let card = subject.compactedCard.frame
        let answer = subject.driver.text(containing: "She named the deadline.").frame
        expect(card.minY < answer.minY, "the compacted card is not before the answer")
    }
}

extension Then where Subject == ProbeSnapshot {
    func sentTheModelNothing() {
        expect(subject.aiRequests.isEmpty, "the AI was asked something: \(subject.aiRequests.first?.prefix(80) ?? "")")
    }
}
