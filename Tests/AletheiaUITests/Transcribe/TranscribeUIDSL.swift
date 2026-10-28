import XCTest

extension Copy {
    static let transcribingTitle = "Transcribing…"
    static let transcriptTab = "Transcript"
    static let importAudio = "Import Audio…"
    static let callAudio = "Call audio"
}

/// The transcript tab on screen.
struct TranscriptOnScreen {
    let driver: AppDriver

    var textView: XCUIElement { driver.app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "[00:")).firstMatch }
    var text: String { (textView.value as? String) ?? "" }
}

extension Given {
    /// Jane Doe with one session whose transcript is a single long turn by `speaker`.
    func aTranscriptWithALongTurn(by speaker: String, run: String? = nil) {
        app.seed {
            if let run { $0.run = run }
            $0.license = "test"
            $0.fileVault = "on"
            $0.patients = [.init(name: "Jane Doe", sessions: 1, transcript: SessionContent.longTurn(by: speaker))]
            $0.open = "Jane Doe"
        }
    }

    /// A session with a recording being transcribed, never finishing.
    func aSessionBeingTranscribed() {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.slowTranscription = true
            $0.importFile = "clip"
            $0.patients = [.init(name: "Jane Doe", sessions: 1, recordingConsent: true)]
            $0.open = "Jane Doe"
        }
    }
}

extension When {
    func importARecording() {
        app.ensureLaunched()
        app.tap(Copy.importAudio)
    }

    /// The transcript once it has laid out, and how many lines it took.
    func readTranscript() -> (transcript: TranscriptOnScreen, lines: Int) {
        app.ensureLaunched()
        let transcript = TranscriptOnScreen(driver: app)
        XCTAssertTrue(app.exists(transcript.textView), "no transcript on screen")
        let probe = app.waitForProbe { $0.transcriptLines > 0 }
        return (transcript, probe.transcriptLines)
    }
}

extension Then where Subject == XCUIElement {
    func bandReadsJustTranscribing() {
        expect(subject.exists, "no progress band titled \"\(Copy.transcribingTitle)\"")
    }
}

extension Then where Subject == TranscriptOnScreen {
    func clientTurnStartsWithFirstName(_ name: String) {
        expect(subject.text.contains("] \(name):"), "the client's turn does not start with \"\(name)\": \(subject.text.prefix(60))")
        expect(!subject.text.contains(Copy.callAudio), "the transcript still says \"\(Copy.callAudio)\"")
    }
}
