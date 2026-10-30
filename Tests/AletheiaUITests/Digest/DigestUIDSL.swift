import XCTest

extension Copy {
    static let digestSummaryRow = "Summaries:"
    static let digestPause = "Pause"
    static let digestResume = "Resume"
    static let digestPausedWords = "paused"
    static let digestCouldntBuild = "Couldn't build the digest"
    static let digestRetry = "Retry"
    static let digestEdit = "Edit"
    static let digestSave = "Save"
    static let digestAllReady = "Summaries: all 1 ready"
}

/// A transcript long enough that its model budget cannot read it whole.
enum DigestContent {
    static func longTranscript(characters: Int = 14_000) -> String {
        var lines: [String] = []
        var size = 0
        var index = 0
        while size < characters {
            let speaker = index % 2 == 0 ? "You" : "Client"
            let line = String(format: "[%02d:%02d] %@: Line %d about how the week went at work and at home.",
                              (index / 2) / 60 % 100, (index / 2) % 60, speaker, index)
            lines.append(line)
            size += line.count + 1
            index += 1
        }
        return lines.joined(separator: "\n")
    }
}

/// The patient page and the session's Transcript tab, as the summaries show on them.
struct SummariesOnScreen {
    let driver: AppDriver

    var row: XCUIElement { driver.anything(containing: Copy.digestSummaryRow) }
    var rowText: String { row.label }
    var pauseButton: XCUIElement { driver.button(Copy.digestPause) }
    var resumeButton: XCUIElement { driver.button(Copy.digestResume) }
    var processing: XCUIElement { driver.element(labelContaining: Copy.processingTranscript) }
    var failure: XCUIElement { driver.anything(containing: Copy.digestCouldntBuild) }
    var retryButton: XCUIElement { driver.button(Copy.digestRetry) }
}

extension Given {
    /// Jane Doe with one long session, the AI model sized to read it only in parts.
    func aLongSession(stageMs: Int? = nil, modelMissing: Bool? = nil) {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.contextTokens = 8192
            $0.aiStageMs = stageMs
            $0.aiModelMissing = modelMissing
            $0.patients = [.init(name: "Jane Doe", sessions: 1, transcript: DigestContent.longTranscript())]
            $0.open = "Jane Doe"
        }
    }
}

extension When {
    func openSummaries() -> SummariesOnScreen {
        app.ensureLaunched()
        return SummariesOnScreen(driver: app)
    }

    func openTranscriptTab(_ screen: SummariesOnScreen) {
        app.tap(Copy.transcriptTab)
    }
}
