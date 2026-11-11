import AppKit
import XCTest

extension Copy {
    static let commentButton = "Comment"
}

/// The floating Comment button on screen, with the words selected above it.
struct CommentButtonOnScreen {
    let driver: AppDriver

    var button: XCUIElement { driver.button(Copy.commentButton) }
    /// The word inside the button.
    var label: XCUIElement { button.staticTexts[Copy.commentButton].firstMatch }

    /// How wide "Comment" is when nothing limits it, in the button's font
    /// (13 point, medium weight).
    var wordWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        return (Copy.commentButton as NSString).size(withAttributes: [.font: font]).width
    }
}

extension Given {
    /// Jane Doe with a saved session whose transcript is a few lines long.
    func aSavedTranscript() {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.patients = [.init(name: "Jane Doe", sessions: 1, transcript: SessionContent.shortTranscript)]
            $0.open = "Jane Doe"
        }
    }
}

extension When {
    /// Double-clicks a word on the transcript's first line, which selects it.
    func selectAFewWords() -> CommentButtonOnScreen {
        app.ensureLaunched()
        app.tap(Copy.transcriptTab)
        let transcript = TranscriptOnScreen(driver: app)
        XCTAssertTrue(app.exists(transcript.textView), "no transcript on screen")
        // The first line sits just under the text view's top inset.
        transcript.textView.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 140, dy: 28)).doubleClick()
        return CommentButtonOnScreen(driver: app)
    }
}

extension Then where Subject == CommentButtonOnScreen {
    func isShown() {
        expect(subject.driver.exists(subject.button), "no Comment button appeared for the selection")
    }

    /// The word fits inside the button: the text is as wide as "Comment" laid
    /// out without limits, and the button's edges clear it on both sides.
    func showsItsWholeLabel() {
        expect(subject.driver.exists(subject.label), "no \"\(Copy.commentButton)\" text inside the button")
        let word = subject.wordWidth
        let label = subject.label.frame
        let button = subject.button.frame
        expect(label.width >= word - 1,
               "the label is \(label.width) wide; \"\(Copy.commentButton)\" needs \(word) (button \(button))")
        expect(label.minX >= button.minX && label.maxX <= button.maxX,
               "the label (\(label.minX) to \(label.maxX)) spills out of the button (\(button.minX) to \(button.maxX))")
    }
}
