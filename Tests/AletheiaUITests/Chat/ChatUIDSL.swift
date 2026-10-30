import XCTest

extension Copy {
    static let askTab = "Ask"
    static let askField = "Ask about this session"
    static let sendButton = "Send"
    static let compactButton = "Compact"
    static let effortLabel = "AI effort"
    static let disclaimer = "AI generated responses can be inaccurate. Double-check responses."
    static let compactedChip = "Conversation compacted"
    /// Words in the request that asks the AI to summarize the conversation.
    static let summaryRequest = "Write a summary that will replace it"
    static let preparingTheAnswer = "Preparing the answer"
    static let readingTheSession = "Reading the session · part 1 of 3"
    static let analyzing = "Analyzing"
    static let myNotesHeader = "My Notes stay private, so the AI never reads them."
}

/// The Ask tab on screen.
struct AskTabOnScreen {
    let driver: AppDriver

    var field: XCUIElement { driver.app.textViews[Copy.askField].firstMatch }
    var send: XCUIElement { driver.button(Copy.sendButton) }
    var compact: XCUIElement { driver.button(Copy.compactButton) }
    var disclaimer: XCUIElement {
        driver.app.descendants(matching: .any).matching(identifier: "chat.disclaimer").firstMatch
    }
    var effortBar: XCUIElement { driver.element(labelContaining: Copy.effortLabel) }
    var compactedCard: XCUIElement { driver.anything(containing: Copy.compactedChip) }
}

extension Given {
    func aSessionToAskAbout(
        myNotes: String? = nil, chat: [Scenario.ChatSeed]? = nil, replies: [String]? = nil,
        stageMs: Int? = nil, parts: Int? = nil, contextTokens: Int? = nil, rules: [Scenario.AIRule]? = nil
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
        XCTAssertTrue(app.exists(tab.field), "no Ask field")
        tab.field.click()
        tab.field.typeText(question)
        tab.send.click()
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

    func statusReads(_ words: String) {
        expect(subject.driver.waitFor(subject.driver.element(labelContaining: words), timeout: 60),
               "the status never read \"\(words)\"")
    }
}
