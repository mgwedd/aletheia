import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

/// The call track shows as the patient's first name. Only the view draws it:
/// the stored transcript, offsets and everything the model reads keep
/// "Call audio". Synthetic text.
@MainActor
final class CallAudioNameTests: XCTestCase {
    private let stored = """
    [00:10] You: How was the week?
    [00:12] Call audio (overlapping): Long.
    [00:20] Call audio: I said call audio: twice.
    """

    func testOnlyCallAudioLabelsAreNamed() {
        XCTAssertEqual(TranscriptStyler.namingCallAudio(stored, as: "Jane"), """
        [00:10] You: How was the week?
        [00:12] Jane (overlapping): Long.
        [00:20] Jane: I said call audio: twice.
        """)
        XCTAssertEqual(TranscriptStyler.namingCallAudio(stored, as: ""), stored)
    }

    private struct Host: View {
        @Binding var text: String
        @State private var selection = ""
        @State private var range: NSRange?
        var body: some View {
            TranscriptTextView(text: $text, comments: [], selection: $selection, selectionRange: $range,
                               callAudioName: "Jane")
        }
    }

    func testTheViewDrawsTheNameAndKeepsTheStoredLabel() throws {
        var text = stored
        let binding = Binding(get: { text }, set: { text = $0 })
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(text: binding))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let textView = try XCTUnwrap(find(in: try XCTUnwrap(window.contentView)))
        let layout = try XCTUnwrap(textView.layoutManager)
        XCTAssertEqual(textView.string, stored, "characters are never rewritten")

        let label = (stored as NSString).range(of: "Call audio")
        let glyphs = layout.glyphRange(forCharacterRange: label, actualCharacterRange: nil)
        XCTAssertEqual(layout.numberOfGlyphs, (stored as NSString).length, "one glyph per character, so line layout holds")
        var drawn = 0
        for g in glyphs.location..<NSMaxRange(glyphs) where layout.propertyForGlyph(at: g) != .null { drawn += 1 }
        XCTAssertEqual(drawn, 1, "one blank the name is drawn into, not the label's ten letters")
        let width = layout.boundingRect(forGlyphRange: glyphs, in: try XCTUnwrap(textView.textContainer)).width
        let expected = ("Jane" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
        XCTAssertEqual(width, expected, accuracy: 4)

        window.orderOut(nil)
    }

    /// A long call-audio turn wraps at the text column like any other turn,
    /// not one letter per line.
    func testALongNamedTurnWrapsNormally() throws {
        let long = "[00:08] Call audio: " + String(repeating: "Okay, you have my consent. Yeah. ", count: 12)
        var text = long
        let binding = Binding(get: { text }, set: { text = $0 })
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(text: binding))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let textView = try XCTUnwrap(find(in: try XCTUnwrap(window.contentView)))
        let layout = try XCTUnwrap(textView.layoutManager)
        layout.ensureLayout(for: try XCTUnwrap(textView.textContainer))

        var lines = 0
        var narrowest = CGFloat.greatestFiniteMagnitude
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            var range = NSRange()
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &range)
            lines += 1
            if NSMaxRange(range) < layout.numberOfGlyphs { narrowest = min(narrowest, used.width) }
            glyph = NSMaxRange(range)
        }
        XCTAssertLessThan(lines, 12, "wrapped into \(lines) lines")
        XCTAssertGreaterThan(narrowest, 300, "a full line holds many words")
        window.orderOut(nil)
    }

    func testCopyTakesTheName() throws {
        let textView = TranscriptTextView.ClickReportingTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        textView.string = stored
        textView.callAudioName = "Jane"
        textView.setSelectedRange(NSRange(location: 0, length: (stored as NSString).length))
        let board = NSPasteboard(name: NSPasteboard.Name("CallAudioNameTests"))
        board.clearContents()
        XCTAssertTrue(textView.writeSelection(to: board, types: textView.writablePasteboardTypes), "\(textView.writablePasteboardTypes)")
        let copied = try XCTUnwrap(board.string(forType: .string))
        XCTAssertTrue(copied.contains("[00:12] Jane: Long."), copied)
        XCTAssertFalse(copied.contains("Call audio:"), copied)
    }

    private func find(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for sub in view.subviews { if let found = find(in: sub) { return found } }
        return nil
    }

    func testExportsNameCallAudio() {
        let md = MarkdownExporter.session(date: Date(), patientName: "Jane Doe", transcript: stored, summary: nil)
        XCTAssertTrue(md.contains("[00:20] Jane: I said call audio: twice."), md)
        XCTAssertFalse(md.contains("Call audio"))
        let session = ArchiveSession(date: Date(), transcript: stored, notes: [], summary: "")
        let files = PatientArchive.files(patientName: "Jane Doe", background: "", sessions: [session], exportedOn: Date())
        let transcript = files.first { $0.path.hasSuffix("Transcript.txt") }?.text ?? ""
        XCTAssertTrue(transcript.contains("[00:12] Jane: Long."), transcript)
        XCTAssertFalse(transcript.contains("Call audio"))
    }

    func testVoiceOverReadsTheName() {
        let textView = TranscriptTextView.ClickReportingTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        textView.string = stored
        textView.callAudioName = "Jane"
        let value = textView.accessibilityValue() ?? ""
        XCTAssertTrue(value.contains("[00:12] Jane: Long."), value)
        let line = (stored as NSString).lineRange(for: NSRange(location: (stored as NSString).range(of: "[00:20]").location, length: 0))
        XCTAssertEqual(textView.accessibilityString(for: line)?.hasPrefix("[00:20] Jane:"), true)
    }
}
