import AppKit
import XCTest

extension Copy {
    static let commentButton = "Comment"
}

/// The floating Comment button on screen, with the words selected above it.
/// On macOS a button is one element with no text inside it, so the label is
/// judged by the button's width.
struct CommentButtonOnScreen {
    let driver: AppDriver

    var button: XCUIElement { driver.button(Copy.commentButton) }

    /// The least width that shows the icon and the whole word: "Comment" and
    /// its icon in the button's font (13 point, medium), the gap a label puts
    /// between them (at least 8 points), and the button's padding (12 points
    /// a side).
    var neededWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let word = (Copy.commentButton as NSString).size(withAttributes: [.font: font]).width
        let icon = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))?.size.width ?? 0
        return icon + 8 + word + 2 * 12
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

    /// The button is wide enough for its icon, the whole word and its padding.
    func showsItsWholeLabel() {
        let width = subject.button.frame.width
        expect(width >= subject.neededWidth,
               "the button is \(width) wide; its icon and \"\(Copy.commentButton)\" need \(subject.neededWidth)")
    }
}
