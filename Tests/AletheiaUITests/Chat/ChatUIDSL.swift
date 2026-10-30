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
        expect(!subject.driver.exists(subject.driver.anything(containing: words)), "\"\(words)\" is still shown")
    }

    func statusReads(_ words: String) {
        expect(subject.driver.waitFor(subject.driver.status(containing: words), timeout: 60),
               "the status never read \"\(words)\"")
    }
}
