import XCTest

extension Copy {
    static let notesTab = "Notes"
    static let lengthButtonPrefix = "Length:"
    static let lengthChoices = ["Concise", "Natural", "Detailed"]
    static let effortChoices = ["Fast", "Normal", "Focus"]
    static let generateButtonPrefix = "Generate "
    static let processingTranscript = "Processing transcript"
    static let coverageLead = "Read: a summary of the whole session"
    static let followUpLookup = "follow-up lookup"
    /// What the scripted model answers when asked which parts to read closely.
    static let lookupPlan = #"{"calls":[{"tool":"read_section","session":"S1","start":"00:00","end":"05:00"}]}"#
    static let lookupPlanPrompt = "You are preparing to answer"
}

/// The Notes tab on screen.
struct NotesTabOnScreen {
    let driver: AppDriver

    var lengthButton: XCUIElement { driver.element(labelStarting: Copy.lengthButtonPrefix) }
    var generateButton: XCUIElement { driver.element(labelStarting: Copy.generateButtonPrefix) }
    var processingStatus: XCUIElement { driver.element(labelContaining: Copy.processingTranscript) }
    var coverage: XCUIElement { driver.text(containing: "Read: ") }

    /// The coverage line's words, wherever XCUI reports them.
    var coverageText: String { coverage.label.isEmpty ? (coverage.value as? String ?? "") : coverage.label }

    func menuItem(_ title: String) -> XCUIElement { driver.app.menuItems[title].firstMatch }
}

extension Given {
    /// Jane Doe with one session, its transcript and nothing else.
    func aSession(transcript: String, length: String? = nil, effort: String? = nil,
                  stageMs: Int? = nil, plansLookups: Bool = false) {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.patients = [.init(name: "Jane Doe", sessions: 1, transcript: transcript)]
            $0.open = "Jane Doe"
            $0.noteLength = length
            $0.noteEffort = effort
            $0.aiStageMs = stageMs
            if plansLookups {
                $0.aiRules = [.init(whenPromptContains: Copy.lookupPlanPrompt, reply: Copy.lookupPlan)]
            }
        }
    }
}

extension When {
    func openNotesTab() -> NotesTabOnScreen {
        app.ensureLaunched()
        app.tap(Copy.notesTab)
        return NotesTabOnScreen(driver: app)
    }

    /// Presses the Generate button and waits for the note's coverage line; its text.
    func generateNote(on tab: NotesTabOnScreen) -> String {
        XCTAssertTrue(app.exists(tab.generateButton), "no Generate button")
        tab.generateButton.click()
        XCTAssertTrue(app.waitFor(tab.coverage, timeout: 90), "the note never ended with a coverage line")
        return tab.coverageText
    }

    /// Clicks the right-hand end of the Length button, well away from its icon.
    func clickLengthButtonAwayFromItsIcon(on tab: NotesTabOnScreen) {
        XCTAssertTrue(app.exists(tab.lengthButton), "no Length button")
        tab.lengthButton.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
    }
}

extension Then where Subject == NotesTabOnScreen {
    func lengthMenuOffers(_ titles: [String]) {
        for title in titles where !subject.driver.exists(subject.menuItem(title)) {
            fail("the Length menu has no \"\(title)\"")
        }
    }

    func statusPasses(through words: String) {
        expect(subject.driver.waitFor(subject.driver.element(labelContaining: words), timeout: 60),
               "the status never read \"\(words)\"")
    }
}

extension Then where Subject == String {
    func coverageCountsFollowUpLookups(_ counts: Bool) {
        expect(subject.contains(Copy.followUpLookup) == counts,
               counts ? "the coverage line does not count follow-up lookups: \(subject)"
                      : "the coverage line counts follow-up lookups: \(subject)")
    }

    func coverageCountsEveryPart() {
        expect(subject.hasPrefix(Copy.coverageLead), "the coverage line does not start with the whole-session summary: \(subject)")
    }
}
