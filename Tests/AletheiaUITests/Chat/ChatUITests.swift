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

    func test_CHAT_03_answerCarriesNoReadLine() {
        given.aSessionToAskAbout(replies: ["She said it has been poor."])
        let tab = when.openAskTab()

        when.ask("What did she say about sleep?", on: tab)

        then(tab).showsText("She said it has been poor.")
        then(tab).doesNotShowText(Copy.readLead)
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

    func test_CHAT_21_compactSitsOnTheEffortBarAndTheDisclaimerUnderTheQuestionBox() {
        given.aSessionToAskAbout(chat: [
            .init(role: "user", text: "What did she say about sleep?"),
            .init(role: "assistant", text: "She said it has been poor."),
        ])
        let tab = when.openAskTab()

        XCTAssertTrue(app.exists(tab.compact), "no Compact button")
        XCTAssertTrue(app.exists(tab.disclaimer), "no accuracy notice")

        then(tab).keepsCompactOnTheEffortBar()
        then(tab).showsDisclaimerUnderTheQuestionBox()
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

    func test_CHAT_23_aFailedCompactionPutsTheQuestionBackInTheBox() {
        executionTimeAllowance = 120
        let filler = String(repeating: "We talked about sleep, work and the move. ", count: 30)
        given.aSessionToAskAbout(
            chat: (0..<5).map { .init(role: $0 % 2 == 0 ? "user" : "assistant", text: "\($0). " + filler) },
            replies: ["She named the deadline."],
            contextTokens: 6_000,
            rules: [.init(whenPromptContains: Copy.summaryRequest, reply: "")])
        let tab = when.openAskTab()

        when.ask("What did she say about the deadline?", on: tab)

        then(tab).hasInTheBox("What did she say about the deadline?")
    }

    func test_CHAT_24() {
        given.aSessionToAskAbout()
        let window = when.openPatientChat()
        then(window).dividerIsEasyToGrab()

        then(when.dragChatsListEdge(of: window, by: 60)).widenedTheList()
        then(when.dragChatsListEdge(of: window, by: -40)).narrowedTheList()
        then(when.dragChatsListEdge(of: window, by: 3000)).leftBothSidesUsable()
        then(when.dragChatsListEdge(of: window, by: -3000)).leftBothSidesUsable()
    }

    func test_CHAT_25_clearSitsLeftOfCompactAndEmptiesTheSessionChat() {
        given.aSessionToAskAbout(chat: [
            .init(role: "user", text: "What did she say about sleep?"),
            .init(role: "assistant", text: "She said it has been poor."),
        ])
        let tab = when.openAskTab()
        XCTAssertTrue(app.exists(tab.clear), "no Clear button")
        then(tab).keepsClearJustLeftOfCompact()

        app.click(tab.clear, "Clear button")

        then(tab).showsText(Copy.askEmptyTitle)
        then(tab).doesNotShowText("She said it has been poor.")

        app.relaunch()

        let reopened = when.openAskTab()
        then(reopened).showsText(Copy.askEmptyTitle)
        then(reopened).doesNotShowText("She said it has been poor.")
    }

    func test_CHAT_26_clearEmptiesThePatientChatAndKeepsItInTheList() {
        given.aSessionToAskAbout(replies: ["She said it has been poor."])
        let window = when.openPatientChat()
        app.tap(Copy.newChatButton)
        when.ask("What did she say about sleep?", on: window.pane)
        then(window.pane).showsText("She said it has been poor.")

        app.click(window.pane.clear, "Clear button")

        then(window.pane).doesNotShowText("She said it has been poor.")
        then(window).listsAChat(titled: Copy.newChatTitle)
    }

    func test_CHAT_35_noReasoningOrMarkersAreShownInAnswersOrTheSummary() {
        given.aSessionToAskAbout(chat: [
            .init(role: "summary", text: "<unused94>thought plan the reply<unused95>Earlier: sleep was poor.<end_of_turn>"),
            .init(role: "user", text: "What did she say about sleep?"),
            .init(role: "assistant", text: "<unused94>thought plan the reply<unused95>She said it has been poor.<end_of_turn>"),
        ])
        let tab = when.openAskTab()

        then(tab).showsText("She said it has been poor.")
        then(tab).showsText("Earlier: sleep was poor.")
        then(tab).showsNoReasoningOrMarkers()
    }

    func test_CHAT_36_theAnswersKeepTheirWidthWhileTheSummaryIsWritten() {
        executionTimeAllowance = 120
        given.aSessionToAskAbout(
            chat: [
                .init(role: "user", text: "What did she say about sleep?"),
                .init(role: "assistant", text: "She said it has been poor, and that it has been getting worse since the move."),
            ],
            stageMs: 20,
            rules: [.init(whenPromptContains: Copy.summaryRequest, reply: "Earlier: sleep was poor.")],
            holdsOpen: true)
        let tab = when.openAskTab()
        XCTAssertTrue(app.waitFor(tab.answerText, timeout: 30), "no answer shown to compact")
        let before = tab.answerText.frame

        app.click(tab.compact, "Compact button")

        then(tab).showsText("Earlier: sleep was poor.")
        XCTAssertTrue(app.waitFor(tab.compactedCard, timeout: 30), "no compacted card")
        then(tab).keepsTheAnswersAsWideAndAboveTheCard(before)
    }

    func test_CHAT_37_aSummaryCutOffAtTheReplyLimitIsThrownAway() {
        executionTimeAllowance = 120
        given.aSessionToAskAbout(
            chat: [
                .init(role: "user", text: "What did she say about sleep?"),
                .init(role: "assistant", text: "She said it has been poor."),
            ],
            rules: [.init(whenPromptContains: Copy.summaryRequest, reply: "Earlier: sleep was", reachesReplyLimit: true)])
        let tab = when.openAskTab()
        then(tab).showsText("She said it has been poor.")

        app.click(tab.compact, "Compact button")

        then(tab).showsText(Copy.summaryDidNotFinish)
        then(tab).doesNotShowText("Earlier: sleep was")
        then(tab).doesNotShowText(Copy.compactedChip)
        then(tab).showsText("She said it has been poor.")

        app.relaunch()

        let reopened = when.openAskTab()
        then(reopened).showsText("She said it has been poor.")
        then(reopened).doesNotShowText("Earlier: sleep was")
    }

    func test_CHAT_27_deleteAllChatsEmptiesTheChatsList() {
        given.aSessionToAskAbout(replies: ["She said it has been poor."])
        let window = when.openPatientChat()
        app.tap(Copy.newChatButton)
        when.ask("What did she say about sleep?", on: window.pane)
        then(window.pane).showsText("She said it has been poor.")

        app.click(window.deleteAll, "Delete All Chats button")
        when.confirm(Copy.deleteAllButton)

        then(window.pane).showsText(Copy.noChatSelected)
        then(window.pane).doesNotShowText("What did she say about sleep?")
    }

    func test_CHAT_28_oneSelectionRunsAcrossAnAnswer() {
        given.aSessionToAskAbout(chat: [
            .init(role: "user", text: "What did she say about sleep?"),
            .init(role: "assistant", text: "## Sleep\nShe said it has been poor.\n\n- Wakes at 3am\n- Naps after lunch\n\n> I'm always tired."),
        ])
        let tab = when.openAskTab()

        then(tab).selectsAcrossTheAnswer(["Sleep", "She said it has been poor.", "Wakes at 3am", "Naps after lunch", "I'm always tired."])
    }

    func test_CHAT_29_depthSitsBesideTheEffortWithThreeChoices() {
        given.aSessionToAskAbout()
        let tab = when.openAskTab()

        then(tab.depth).offersTheDepths()
        then(tab.depth).hasChosen("Natural")
        then(tab).keepsDepthBesideTheEffort()

        let window = when.openPatientChat()
        then(window.depth).offersTheDepths()
        then(window.depth).hasChosen("Natural")
    }

    func test_CHAT_30_askDepthSettingSeedsTheChatAndTheChatCanChangeIt() {
        given.aSessionToAskAbout(askDepth: "concise")
        let tab = when.openAskTab()
        then(tab.depth).hasChosen("Concise")

        when.chooseDepth("Detailed", on: tab)

        then(tab.depth).hasChosen("Detailed")
    }
}

extension Then where Subject == AskTabOnScreen {
    /// The heading, paragraph, list and quote sit in one selectable text, so one drag spans them.
    func selectsAcrossTheAnswer(_ pieces: [String]) {
        let answer = subject.answerText
        expect(subject.driver.waitFor(answer, timeout: 30), "no selectable answer text")
        let value = answer.value as? String ?? ""
        expect(pieces.allSatisfy { value.contains($0) }, "one selectable text does not hold \(pieces): \"\(value)\"")
    }

    func keepsCompactOnTheEffortBar() {
        let compact = subject.compact.frame
        let effort = subject.effortBar.frame
        expect(abs(compact.midY - effort.midY) < 24, "Compact is not level with the AI effort bar: \(compact) vs \(effort)")
        expect(compact.minX > effort.minX, "Compact is not at the trailing end of the effort bar")
    }

    func keepsClearJustLeftOfCompact() {
        let clear = subject.clear.frame
        let compact = subject.compact.frame
        expect(abs(clear.midY - compact.midY) < 4, "Clear is not level with Compact: \(clear) vs \(compact)")
        expect(clear.maxX <= compact.minX && compact.minX - clear.maxX < 24,
               "Clear is not just left of Compact: \(clear) vs \(compact)")
    }

    func showsDisclaimerUnderTheQuestionBox() {
        let notice = subject.disclaimer
        let text = notice.label.isEmpty ? (notice.value as? String ?? "") : notice.label
        expect(text == Copy.disclaimer, "the accuracy notice reads \"\(text)\"")
        let field = subject.field.frame
        expect(notice.frame.minY >= field.maxY, "the accuracy notice is not under the question box: \(notice.frame) vs \(field)")
        expect(notice.frame.minX <= field.minX + 8, "the accuracy notice is not at the left of the question box: \(notice.frame) vs \(field)")
        // Small print: at most two 10pt lines, as a narrow pane wraps it.
        expect(notice.frame.height <= 30, "the accuracy notice is not small print: \(notice.frame)")
    }

    func showsCompactedCardAboveTheAnswer() {
        let card = subject.compactedCard.frame
        let answer = subject.driver.anything(containing: "She named the deadline.").frame
        expect(card.minY < answer.minY, "the compacted card is not before the answer")
    }
}

extension Then where Subject == ProbeSnapshot {
    func sentTheModelNothing() {
        expect(subject.aiRequests.isEmpty, "the AI was asked something: \(subject.aiRequests.first?.prefix(80) ?? "")")
    }
}
