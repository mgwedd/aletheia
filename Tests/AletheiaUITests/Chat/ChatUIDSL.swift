import XCTest

extension Copy {
    static let askTab = "Ask"
    static let askField = "Ask about this session"
    static let sendButton = "Send"
    static let disclaimer = "AI generated responses can be inaccurate. Double-check responses."
    static let compactedChip = "Conversation compacted"
    /// Words in the request that asks the AI to summarize the conversation.
    static let summaryRequest = "Write a summary that will replace it"
    static let summaryDidNotFinish = "The summary didn't finish, so the conversation was kept as it was."
    static let preparingTheAnswer = "Preparing the answer"
    static let readingTheSession = "Reading the session · part 1 of 3"
    static let analyzing = "Analyzing"
    static let myNotesHeader = "My Notes stay private, so the AI never reads them."
    static let askEmptyTitle = "Ask a question about this session"
    static let readLead = "Read:"
    static let stopButton = "Stop"
    static let modelMissingTitle = "The AI model isn't downloaded"
    static let deleteAllButton = "Delete All"
    /// What a model writes around its answer, and the app must not show.
    static let hiddenReasoningMarkers = ["unused94", "unused95", "end_of_turn", "plan the reply"]
    static let newChatButton = "New Chat"
    static let newChatTitle = "New chat"
    static let noChatSelected = "No Chat Selected"
}

/// The Ask tab on screen, found by the identifiers the app gives its parts.
struct AskTabOnScreen {
    let driver: AppDriver

    var field: XCUIElement { driver.app.textViews["chat.ask-field"].firstMatch }
    var send: XCUIElement { driver.app.buttons["chat.send"].firstMatch }
    var compact: XCUIElement { driver.app.buttons["chat.compact"].firstMatch }
    var clear: XCUIElement { driver.app.buttons["chat.clear"].firstMatch }
    var disclaimer: XCUIElement { driver.element(id: "chat.disclaimer") }
    var effortBar: XCUIElement { driver.element(id: "chat.effort") }
    var answerText: XCUIElement { driver.app.textViews.matching(identifier: "chat.answer-text").firstMatch }
    var depthBar: XCUIElement { driver.element(id: "chat.depth") }
    var compactedCard: XCUIElement { driver.element(id: "chat.compacted") }
    var stop: XCUIElement { driver.app.buttons[Copy.stopButton].firstMatch }
}

extension Given {
    func aSessionToAskAbout(
        myNotes: String? = nil, chat: [Scenario.ChatSeed]? = nil, replies: [String]? = nil,
        stageMs: Int? = nil, parts: Int? = nil, contextTokens: Int? = nil, modelMissing: Bool? = nil, rules: [Scenario.AIRule]? = nil,
        askDepth: String? = nil, holdsOpen: Bool? = nil
    ) {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.patients = [.init(name: "Jane Doe", sessions: 1, transcript: SessionContent.shortTranscript,
                                 myNotes: myNotes, chat: chat)]
            $0.open = "Jane Doe"
            $0.aiReplies = replies
            $0.aiStageMs = stageMs
            $0.aiRules = rules
            $0.aiParts = parts
            $0.contextTokens = contextTokens
            $0.aiModelMissing = modelMissing
            $0.askDepth = askDepth
            // With a stage time the answer is written a word at a time, so it is seen being written.
            $0.aiStreamsWords = stageMs != nil ? true : nil
            // With it, a written answer stays open, so a test can look at the screen while it is being written.
            $0.aiHoldsOpen = holdsOpen
        }
    }
}

extension When {
    func openAskTab() -> AskTabOnScreen {
        app.ensureLaunched()
        app.tap(Copy.askTab)
        return AskTabOnScreen(driver: app)
    }

    /// Clicks `button` in the confirmation that Delete All put up.
    func confirm(_ button: String) {
        let choice = app.app.buttons
            .matching(NSPredicate(format: "label == %@ AND identifier != %@", button, "chat.clear")).firstMatch
        app.click(choice, "\"\(button)\" in the confirmation")
    }

    func ask(_ question: String, on tab: AskTabOnScreen) {
        app.click(tab.field, "\"\(Copy.askField)\" field")
        app.enter(question, into: tab.field)
        app.click(tab.send, "\(Copy.sendButton) button")
    }
}

extension Then where Subject == AskTabOnScreen {
    func hasInTheBox(_ question: String) {
        let field = subject.field
        let held = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", question), object: field)
        expect(XCTWaiter().wait(for: [held], timeout: 60) == .completed,
               "the Ask box reads \"\(field.value as? String ?? "")\", not the question")
    }

    func showsText(_ words: String) {
        expect(subject.driver.waitFor(subject.driver.anything(containing: words), timeout: 60), "\"\(words)\" never appeared")
    }

    func showsStop() {
        expect(subject.driver.waitFor(subject.stop, timeout: 30), "no Stop button while the answer is being written")
    }

    func doesNotShowText(_ words: String) {
        expect(subject.driver.gone(subject.driver.anything(containing: words)), "\"\(words)\" is still shown")
    }

    /// Neither the reasoning a model writes before its answer nor its template markers are on screen.
    func showsNoReasoningOrMarkers() {
        for marker in Copy.hiddenReasoningMarkers {
            expect(subject.driver.gone(subject.driver.anything(containing: marker)), "\"\(marker)\" is shown")
        }
        let shown = subject.driver.app.textViews.matching(identifier: "chat.answer-text").allElementsBoundByIndex
            .map { $0.value as? String ?? "" }
        for marker in Copy.hiddenReasoningMarkers {
            expect(!shown.contains { $0.contains(marker) }, "an answer reads \"\(shown.joined(separator: " | "))\"")
        }
    }

    /// The answers above keep their width while the summary is written, and the card is below them.
    func keepsTheAnswersAsWideAndAboveTheCard(_ before: CGRect) {
        let answer = subject.answerText.frame
        let card = subject.compactedCard.frame
        expect(abs(answer.width - before.width) < 2, "the answer went from \(before.width) to \(answer.width) wide")
        expect(answer.maxY <= card.minY + 1, "the answer (\(answer)) runs into the compacted card (\(card))")
    }

    func statusReads(_ words: String) {
        expect(subject.driver.waitFor(subject.driver.status(containing: words), timeout: 60),
               "the status never read \"\(words)\"")
    }
}

// MARK: - Patient chat window

extension Copy {
    static let askAboutThisPatient = "Ask about this patient"
}

/// The patient chat window on screen: the Chats list, the divider and the chat.
struct PatientChatOnScreen {
    let driver: AppDriver
    var list: XCUIElement { driver.element(id: "chat-threads-list") }
    var chat: XCUIElement { driver.element(id: "chat-pane") }
    var divider: XCUIElement { driver.element(id: "chat-threads-divider") }
    var deleteAll: XCUIElement { driver.app.buttons["chat.delete-all"].firstMatch }
    /// The open chat, which has the same parts as a session's Ask tab.
    var pane: AskTabOnScreen { AskTabOnScreen(driver: driver) }
    var depthBar: XCUIElement { driver.element(id: "chat.depth") }
}

/// The Chats list's width before and after its divider was dragged.
struct ChatsListDragOnScreen {
    let before: CGFloat
    let after: CGFloat
    let window: PatientChatOnScreen
}

extension When {
    func openPatientChat() -> PatientChatOnScreen {
        app.ensureLaunched()
        app.tap(Copy.askAboutThisPatient)
        let window = PatientChatOnScreen(driver: app)
        XCTAssertTrue(app.exists(window.divider), "the patient chat window has no divider beside the Chats list")
        return window
    }

    /// Drags the divider between the Chats list and the chat by `points`.
    func dragChatsListEdge(of window: PatientChatOnScreen, by points: CGFloat) -> ChatsListDragOnScreen {
        let before = window.list.frame.width
        let start = window.divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: points, dy: 0)))
        // A drag under the narrowest springs back once let go.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        return ChatsListDragOnScreen(before: before, after: window.list.frame.width, window: window)
    }
}

extension Then where Subject == PatientChatOnScreen {
    /// The divider's grab area is wide enough to catch with the mouse.
    func dividerIsEasyToGrab() {
        expect(subject.divider.frame.width >= 12, "the divider's grab area is \(subject.divider.frame.width) wide")
    }
}

extension Then where Subject == PatientChatOnScreen {
    func listsAChat(titled title: String) {
        let row = subject.list.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
        expect(subject.driver.waitFor(row, timeout: 30), "the Chats list has no chat titled \"\(title)\"")
    }
}

extension Then where Subject == ChatsListDragOnScreen {
    func widenedTheList() {
        expect(subject.after > subject.before + 20, "the Chats list went from \(subject.before) to \(subject.after) wide")
    }

    func narrowedTheList() {
        expect(subject.after < subject.before - 20, "the Chats list went from \(subject.before) to \(subject.after) wide")
    }

    func leftBothSidesUsable() {
        expect(subject.after >= 200, "the Chats list narrowed to \(subject.after)")
        expect(subject.after <= 320, "the Chats list widened to \(subject.after)")
        expect(subject.window.chat.frame.width >= 360, "the chat narrowed to \(subject.window.chat.frame.width)")
    }
}

// MARK: - Depth

extension When {
    func chooseDepth(_ name: String, on tab: AskTabOnScreen) {
        app.click(tab.depthBar.buttons[name].firstMatch, "\(name) on the Ask bar's Depth")
    }
}

/// A Depth control on an Ask bar.
struct DepthBarOnScreen {
    let bar: XCUIElement
    let driver: AppDriver
}

extension AskTabOnScreen {
    var depth: DepthBarOnScreen { DepthBarOnScreen(bar: depthBar, driver: driver) }
}

extension PatientChatOnScreen {
    var depth: DepthBarOnScreen { DepthBarOnScreen(bar: depthBar, driver: driver) }
}

extension Then where Subject == DepthBarOnScreen {
    func offersTheDepths() {
        expect(subject.driver.waitFor(subject.bar, timeout: 30), "no Depth control on the Ask bar")
        for name in Copy.depthChoices {
            expect(subject.bar.buttons[name].exists, "the Depth control does not offer \(name)")
        }
    }

    func hasChosen(_ name: String) {
        let button = subject.bar.buttons[name].firstMatch
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: button)
        expect(XCTWaiter().wait(for: [chosen], timeout: 30) == .completed, "\(name) is not the chosen depth")
        for other in Copy.depthChoices where other != name {
            expect(!subject.bar.buttons[other].firstMatch.isSelected, "\(other) is chosen as well as \(name)")
        }
    }
}

extension Then where Subject == AskTabOnScreen {
    func keepsDepthBesideTheEffort() {
        let depth = subject.depthBar.frame
        let effort = subject.effortBar.frame
        expect(abs(depth.midY - effort.midY) < 24, "Depth is not level with the AI effort: \(depth) vs \(effort)")
        expect(depth.minX >= effort.maxX, "Depth is not just after the AI effort: \(depth) vs \(effort)")
    }
}
