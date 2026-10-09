import XCTest
import AppKit
@testable import Aletheia

final class NoteRichTextTests: XCTestCase {
    private let fonts = NoteRichText.Fonts.sans

    private func load(_ markdown: String, fonts: NoteRichText.Fonts? = nil) -> NSAttributedString {
        NoteRichText.attributedString(fromMarkdown: markdown, font: fonts ?? self.fonts)
    }

    private func roundTrip(_ markdown: String) -> String {
        NoteRichText.markdown(from: load(markdown))
    }

    /// The block type of each paragraph, in order.
    private func blocks(of attributed: NSAttributedString) -> [String] {
        let text = attributed.string as NSString
        var result: [String] = []
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            let raw = attributed.attribute(NoteRichText.blockKey, at: paragraph.location, effectiveRange: nil) as? String
            result.append(raw ?? "none")
            location = NSMaxRange(paragraph)
        }
        return result
    }

    // MARK: Round trips

    func testEmptyStringRoundTrips() {
        XCTAssertEqual(roundTrip(""), "")
        XCTAssertEqual(load("").length, 0)
    }

    func testPlainParagraphsRoundTrip() {
        let markdown = "First paragraph.\n\nSecond paragraph, a little longer.\n\nThird."
        XCTAssertEqual(roundTrip(markdown), markdown)
    }

    func testSingleNewlineInsideParagraphRoundTrips() {
        let markdown = "Line one\nLine two\n\nNext"
        XCTAssertEqual(roundTrip(markdown), markdown)
    }

    func testHeadingAndParagraphRoundTrip() {
        let markdown = "## Heading\n\nSome text under it."
        XCTAssertEqual(roundTrip(markdown), markdown)
    }

    func testSubheadingWithListRoundTrips() {
        let markdown = "### Sub\n\n- one\n- two"
        XCTAssertEqual(roundTrip(markdown), markdown)
    }

    func testBoldItalicAndBothInsideASentenceRoundTrip() {
        XCTAssertEqual(roundTrip("A **bold** word."), "A **bold** word.")
        XCTAssertEqual(roundTrip("An *italic* word."), "An *italic* word.")
        XCTAssertEqual(roundTrip("Both ***together*** here."), "Both ***together*** here.")
        XCTAssertEqual(
            roundTrip("Mix of **bold**, *italic* and ***both*** in one."),
            "Mix of **bold**, *italic* and ***both*** in one."
        )
    }

    func testBulletedListRoundTrips() {
        let markdown = "- apples\n- **pears**\n- plums"
        XCTAssertEqual(roundTrip(markdown), markdown)
    }

    func testNumberedListRoundTripsAndRenumbers() {
        let markdown = "1. first\n2. second\n3. third"
        XCTAssertEqual(roundTrip(markdown), markdown)
        XCTAssertEqual(roundTrip("1. first\n1. second\n1. third"), markdown)
    }

    func testMixedDocumentRoundTrips() {
        let markdown = """
        ## Session summary

        The client arrived **on time** and seemed *calm*.

        ### Themes

        - Sleep
        - Work stress

        ### Plan

        1. Breathing exercises
        2. Journal daily

        Follow up next week.
        """
        XCTAssertEqual(roundTrip(markdown), markdown)
    }

    func testCodeFenceIsPreservedVerbatim() {
        let markdown = "Before\n\n```swift\nlet x = 1\n\nlet **y** = 2\n```\n\nAfter"
        XCTAssertEqual(roundTrip(markdown), markdown)
    }

    func testQuoteIsPreservedVerbatim() {
        let markdown = "> a quoted line\n> and **another**\n\nPlain"
        XCTAssertEqual(roundTrip(markdown), markdown)
    }

    func testUnsupportedSyntaxIsNotLost() {
        for markdown in [
            "| a | b |\n| - | - |\n| 1 | 2 |",
            "See [the guide](https://example.com) for more.",
            "Use `code` here.",
            "<div>html</div>",
            "---",
            "Escaped \\*star\\*.",
        ] {
            XCTAssertEqual(roundTrip(markdown), markdown, markdown)
        }
    }

    func testPlainTextWithLooseAsterisksIsUnchanged() {
        let markdown = "Dose 5 * 3 mg, then 2 * 1 mg."
        XCTAssertEqual(roundTrip(markdown), markdown)
    }

    // MARK: Structure

    func testHashHeadingLoadsAsHeadingAndSavesAsTwoHashes() {
        let attributed = load("# Title\n\nBody")
        XCTAssertEqual(blocks(of: attributed), ["heading", "body"])
        XCTAssertEqual(NoteRichText.markdown(from: attributed), "## Title\n\nBody")
    }

    func testEveryParagraphCarriesItsBlockType() {
        let attributed = load("## H\n\n### S\n\nText\n\n- b\n\n1. n\n\n> q")
        XCTAssertEqual(blocks(of: attributed), ["heading", "subheading", "body", "bullet", "numbered", "literal"])
    }

    func testBlankLinesBecomeSpacingNotEmptyParagraphs() {
        let attributed = load("a\n\nb\n\nc")
        XCTAssertEqual(attributed.string, "a\nb\nc")
        let first = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(first?.paragraphSpacing, fonts.blockSpacing)
    }

    func testConsecutiveListItemsAreOneList() {
        let attributed = load("- a\n- b\n\nafter")
        XCTAssertEqual(blocks(of: attributed), ["bullet", "bullet", "body"])
        let first = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(first?.paragraphSpacing, 3)
    }

    func testListMarkersAreShownButNotSaved() {
        let attributed = load("- one\n\n1. two")
        XCTAssertTrue(attributed.string.contains("\u{2022}\t"))
        XCTAssertTrue(attributed.string.contains("1.\t"))
        let saved = NoteRichText.markdown(from: attributed)
        XCTAssertEqual(saved, "- one\n\n1. two")
        XCTAssertFalse(saved.contains("\u{2022}"))
        XCTAssertFalse(saved.contains("\t"))
    }

    func testListParagraphsHangWrappedLines() {
        let attributed = load("- one")
        let style = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.headIndent, NoteRichText.listTextIndent)
        XCTAssertEqual(style?.tabStops.first?.location, NoteRichText.listTextIndent)
    }

    // MARK: Fonts

    func testInlineEmphasisUsesFontTraits() throws {
        let attributed = load("plain **bold** *italic* ***both***")
        let text = attributed.string as NSString

        func traits(of word: String) throws -> (bold: Bool, italic: Bool) {
            let range = text.range(of: word)
            XCTAssertNotEqual(range.location, NSNotFound)
            let font = try XCTUnwrap(attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            return NoteRichText.traits(of: font)
        }

        let plain = try traits(of: "plain")
        XCTAssertFalse(plain.bold)
        XCTAssertFalse(plain.italic)
        let bold = try traits(of: "bold")
        XCTAssertTrue(bold.bold)
        XCTAssertFalse(bold.italic)
        let italic = try traits(of: "italic")
        XCTAssertFalse(italic.bold)
        XCTAssertTrue(italic.italic)
        let both = try traits(of: "both")
        XCTAssertTrue(both.bold)
        XCTAssertTrue(both.italic)
    }

    func testBoldRunEndingWithSpaceKeepsTheSpaceOutsideTheMarkers() {
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: "bold ", attributes: fonts.attributes(for: .body, bold: true)))
        attributed.append(NSAttributedString(string: "word", attributes: fonts.attributes(for: .body)))
        XCTAssertEqual(NoteRichText.markdown(from: attributed), "**bold** word")
    }

    func testBoldRunStartingWithSpaceKeepsTheSpaceOutsideTheMarkers() {
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: "a", attributes: fonts.attributes(for: .body)))
        attributed.append(NSAttributedString(string: " bold", attributes: fonts.attributes(for: .body, bold: true)))
        XCTAssertEqual(NoteRichText.markdown(from: attributed), "a **bold**")
    }

    func testAdjacentRunsWithTheSameStyleMerge() {
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: "one ", attributes: fonts.attributes(for: .body, bold: true)))
        var other = fonts.attributes(for: .body, bold: true)
        other[.foregroundColor] = Theme.muted.nsColor
        attributed.append(NSAttributedString(string: "two", attributes: other))
        XCTAssertEqual(NoteRichText.markdown(from: attributed), "**one two**")
    }

    func testHeadingsIgnoreBoldOnSave() {
        let attributed = load("## **Loud** title")
        XCTAssertEqual(NoteRichText.markdown(from: attributed), "## Loud title")
    }

    func testSerifFontsUseTheNoteSizes() {
        let attributed = load("## H\n\n### S\n\nText", fonts: .serif)
        let text = attributed.string as NSString
        func size(of word: String) -> CGFloat {
            let font = attributed.attribute(.font, at: text.range(of: word).location, effectiveRange: nil) as? NSFont
            return font?.pointSize ?? 0
        }
        XCTAssertEqual(size(of: "H"), 20)
        XCTAssertEqual(size(of: "S"), 16)
        XCTAssertEqual(size(of: "Text"), 16)
        XCTAssertEqual(NoteRichText.markdown(from: attributed), "## H\n\n### S\n\nText")
    }

    // MARK: Editing support

    func testNormalizeRenumbersAfterAnItemIsRemoved() {
        let attributed = NSMutableAttributedString(attributedString: load("1. a\n2. b\n3. c"))
        let first = (attributed.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        attributed.deleteCharacters(in: first)
        _ = NoteRichText.normalize(attributed, fonts: fonts, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(attributed.string, "1.\tb\n2.\tc")
        XCTAssertEqual(NoteRichText.markdown(from: attributed), "1. b\n2. c")
    }

    func testNormalizeAddsAMarkerToAnUnmarkedListParagraph() {
        let attributed = NSMutableAttributedString(attributedString: load("- a"))
        attributed.append(NSAttributedString(string: "\n", attributes: fonts.attributes(for: .bullet)))
        attributed.append(NSAttributedString(string: "b", attributes: fonts.attributes(for: .bullet)))
        let selection = NoteRichText.normalize(attributed, fonts: fonts, selection: NSRange(location: attributed.length, length: 0))
        XCTAssertEqual(attributed.string, "\u{2022}\ta\n\u{2022}\tb")
        XCTAssertEqual(selection.location, attributed.length)
        XCTAssertEqual(NoteRichText.markdown(from: attributed), "- a\n- b")
    }

    func testConvertingBodyToListAndBack() {
        let body = load("some text")
        let bullet = NoteRichText.converting(body, to: .bullet, fonts: fonts)
        XCTAssertEqual(bullet.string, "\u{2022}\tsome text")
        XCTAssertEqual(NoteRichText.markdown(from: bullet), "- some text")

        let backToBody = NoteRichText.converting(bullet, to: .body, fonts: fonts)
        XCTAssertEqual(backToBody.string, "some text")
        XCTAssertEqual(NoteRichText.markdown(from: backToBody), "some text")
    }

    func testConvertingKeepsBoldAndDropsItFromHeadings() {
        let body = load("a **b** c")
        let heading = NoteRichText.converting(body, to: .heading, fonts: fonts)
        XCTAssertEqual(NoteRichText.markdown(from: heading), "## a b c")
        let list = NoteRichText.converting(body, to: .bullet, fonts: fonts)
        XCTAssertEqual(NoteRichText.markdown(from: list), "- a **b** c")
    }
}
