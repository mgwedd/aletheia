import XCTest

extension Copy {
    static let askTab = "Ask"
    static let askField = "Ask about this session"
    static let sendButton = "Send"
    static let disclaimer = "AI generated responses can be inaccurate. Double-check responses."
    static let compactedChip = "Conversation compacted"
    /// Words in the request that asks the AI to summarize the conversation.
    static let summaryRequest = "Write a summary that will replace it"
    static let preparingTheAnswer = "Preparing the answer"
    static let readingTheSession = "Reading the session · part 1 of 3"
    static let analyzing = "Analyzing"
    static let myNotesHeader = "My Notes stay private, so the AI never reads them."
    static let askEmptyTitle = "Ask a question about this session"
    static let readLead = "Read:"
    static let stopButton = "Stop"
    static let modelMissingTitle = "The AI model isn't downloaded"
}

/// The Ask tab on screen, found by the identifiers the app gives its parts.
struct AskTabOnScreen {
    let driver: AppDriver

    var field: XCUIElement { driver.app.textViews["chat.ask-field"].firstMatch }
    var send: XCUIElement { driver.app.buttons["chat.send"].firstMatch }
    var compact: XCUIElement { driver.app.buttons["chat.compact"].firstMatch }
    var disclaimer: XCUIElement { driver.element(id: "chat.disclaimer") }
    var effortBar: XCUIElement { driver.element(id: "chat.effort") }
    var compactedCard: XCUIElement { driver.element(id: "chat.compacted") }
    var stop: XCUIElement { driver.app.buttons[Copy.stopButton].firstMatch }
}

extension Given {
    func aSessionToAskAbout(
        myNotes: String? = nil, chat: [Scenario.ChatSeed]? = nil, replies: [String]? = nil,
        stageMs: Int? = nil, parts: Int? = nil, contextTokens: Int? = nil, modelMissing: Bool? = nil, rules: [Scenario.AIRule]? = nil
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
            // With a stage time the answer is written a word at a time, so it is seen being written.
            $0.aiStreamsWords = stageMs != nil ? true : nil
        }
    }
}

extension When {
    func openAskTab() -> AskTabOnScreen {
        app.ensureLaunched()
        app.tap(Copy.askTab)
        return AskTabOnScreen(driver: app)
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
