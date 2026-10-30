import XCTest
import AppKit
@testable import Aletheia

/// How the session pane shares its width between the transcript and its comments.
final class TranscriptSplitTests: XCTestCase {
    private typealias Split = TranscriptSplit

    // MARK: - Layout

    func testNoCommentsGivesTheTranscriptEverything() {
        let choices: [Split.Side?] = [nil, .comments, .transcript]
        for collapsed in choices {
            XCTAssertEqual(
                Split.layout(total: 500, ratio: Split.defaultRatio, hasComments: false, collapsed: collapsed),
                Split.Layout(transcript: 500, comments: 0, strip: nil, showsDivider: false)
            )
        }
    }

    func testCommentsTakeTheirShareAtTheDefaultRatio() {
        // 901 = 600 + 1 divider + 300: two thirds and one third.
        let layout = Split.layout(total: 901, ratio: Split.defaultRatio, hasComments: true, collapsed: nil)
        XCTAssertEqual(layout, Split.Layout(transcript: 600, comments: 300, strip: nil, showsDivider: true))
        XCTAssertEqual(layout.transcript + Split.dividerWidth + layout.comments, 901)
    }

    func testEachSideKeepsItsMinimumWhileBothShow() {
        let tiny = Split.layout(total: 901, ratio: 0.1, hasComments: true, collapsed: nil)
        XCTAssertEqual(tiny.transcript, Split.minTranscript)
        let huge = Split.layout(total: 901, ratio: 0.9, hasComments: true, collapsed: nil)
        XCTAssertEqual(huge.comments, Split.minComments)
        XCTAssertEqual(huge.transcript + Split.dividerWidth + huge.comments, 901)
    }

    func testANarrowPaneFoldsTheCommentsAwayRatherThanSqueezingTheTranscript() {
        let layout = Split.layout(total: 300, ratio: Split.defaultRatio, hasComments: true, collapsed: nil)
        XCTAssertEqual(layout.strip, .comments)
        XCTAssertEqual(layout.comments, 0)
        XCTAssertEqual(layout.transcript, 300 - Split.stripWidth)
        XCTAssertFalse(layout.showsDivider)
    }

    func testTheSmallestPaneThatFitsBothShowsBoth() {
        let fits = Split.minTranscript + Split.dividerWidth + Split.minComments
        XCTAssertTrue(Split.fitsBoth(total: fits))
        XCTAssertFalse(Split.fitsBoth(total: fits - 1))
        XCTAssertNil(Split.layout(total: fits, ratio: Split.defaultRatio, hasComments: true, collapsed: nil).strip)
        XCTAssertEqual(Split.layout(total: fits - 1, ratio: Split.defaultRatio, hasComments: true, collapsed: nil).strip, .comments)
    }

    func testAChosenCollapseHoldsEvenWhenThereIsRoom() {
        let comments = Split.layout(total: 901, ratio: Split.defaultRatio, hasComments: true, collapsed: .comments)
        XCTAssertEqual(comments, Split.Layout(transcript: 901 - Split.stripWidth, comments: 0, strip: .comments, showsDivider: false))
        let transcript = Split.layout(total: 901, ratio: Split.defaultRatio, hasComments: true, collapsed: .transcript)
        XCTAssertEqual(transcript, Split.Layout(transcript: 0, comments: 901 - Split.stripWidth, strip: .transcript, showsDivider: false))
    }

    func testACollapsedTranscriptStaysCollapsedInANarrowPane() {
        let layout = Split.layout(total: 400, ratio: Split.defaultRatio, hasComments: true, collapsed: .transcript)
        XCTAssertEqual(layout.strip, .transcript)
        XCTAssertEqual(layout.comments, 400 - Split.stripWidth)
    }

    // MARK: - Ratio

    func testRatioIsKeptInRangeAndFiniteValuesOnly() {
        XCTAssertEqual(Split.sanitized(ratio: 0.5), 0.5)
        XCTAssertEqual(Split.sanitized(ratio: -3), Split.ratioRange.lowerBound)
        XCTAssertEqual(Split.sanitized(ratio: 7), Split.ratioRange.upperBound)
        XCTAssertEqual(Split.sanitized(ratio: .nan), Split.defaultRatio)
        XCTAssertEqual(Split.sanitized(ratio: .infinity), Split.defaultRatio)
    }

    func testDefaultIsTwoThirdsTranscript() {
        XCTAssertEqual(Split.defaultRatio, 2.0 / 3.0, accuracy: 1e-9)
    }

    // MARK: - Dragging

    func testDragWithinRangeResizes() {
        XCTAssertEqual(Split.resolveDrag(proposedTranscript: 600, total: 901), .resize(ratio: 600.0 / 900.0))
    }

    func testThresholdsLetTheTranscriptGetNarrowBeforeSnapping() {
        XCTAssertEqual(Split.minTranscript, 200)
        XCTAssertEqual(Split.minComments, 180)
        XCTAssertEqual(Split.collapseSlack, 80)
        // The transcript can be dragged down to 120 before it snaps shut.
        XCTAssertEqual(Split.minTranscript - Split.collapseSlack, 120)
    }

    func testDragStopsAtTheMinimumBeforeCollapsing() {
        // Up to `collapseSlack` past a minimum the side holds at its minimum.
        XCTAssertEqual(Split.resolveDrag(proposedTranscript: 150, total: 901), .resize(ratio: 200.0 / 900.0))
        XCTAssertEqual(
            Split.resolveDrag(proposedTranscript: Split.minTranscript - Split.collapseSlack, total: 901),
            .resize(ratio: 200.0 / 900.0)
        )
        XCTAssertEqual(
            Split.resolveDrag(proposedTranscript: Split.minTranscript - Split.collapseSlack - 1, total: 901),
            .collapse(.transcript)
        )
    }

    func testDragPastTheCommentsMinimumCollapsesThem() {
        // usable = 900; comments are 900 - proposed.
        XCTAssertEqual(Split.resolveDrag(proposedTranscript: 690, total: 901), .resize(ratio: 690.0 / 900.0))
        XCTAssertEqual(Split.resolveDrag(proposedTranscript: 800, total: 901), .resize(ratio: 720.0 / 900.0))
        XCTAssertEqual(Split.resolveDrag(proposedTranscript: 801, total: 901), .collapse(.comments))
    }

    // MARK: - Dragging out of a collapsed strip

    func testDragOriginIsWhereTheDividerIs() {
        let both = Split.layout(total: 901, ratio: Split.defaultRatio, hasComments: true, collapsed: nil)
        XCTAssertEqual(Split.dragOrigin(both, total: 901), 600)
        let comments = Split.layout(total: 901, ratio: Split.defaultRatio, hasComments: true, collapsed: .comments)
        XCTAssertEqual(Split.dragOrigin(comments, total: 901), 901 - Split.stripWidth)
        let transcript = Split.layout(total: 901, ratio: Split.defaultRatio, hasComments: true, collapsed: .transcript)
        XCTAssertEqual(Split.dragOrigin(transcript, total: 901), Split.stripWidth)
    }

    func testDraggingTheCommentsStripOutwardsReopensThem() {
        let layout = Split.layout(total: 901, ratio: Split.defaultRatio, hasComments: true, collapsed: .comments)
        let origin = Split.dragOrigin(layout, total: 901)
        // Barely moved, or dragged further shut: still collapsed.
        XCTAssertEqual(Split.resolveDrag(proposedTranscript: origin, total: 901), .collapse(.comments))
        XCTAssertEqual(Split.resolveDrag(proposedTranscript: origin + 30, total: 901), .collapse(.comments))
        // Dragged until the comments would be 100 wide: they open and follow the mouse.
        XCTAssertEqual(Split.resolveDrag(proposedTranscript: origin - 110, total: 901), .resize(ratio: 720.0 / 900.0))
        XCTAssertEqual(Split.resolveDrag(proposedTranscript: origin - 300, total: 901), .resize(ratio: 577.0 / 900.0))
    }

    func testDraggingTheTranscriptStripOutwardsReopensIt() {
        let layout = Split.layout(total: 901, ratio: Split.defaultRatio, hasComments: true, collapsed: .transcript)
        let origin = Split.dragOrigin(layout, total: 901)
        XCTAssertEqual(Split.resolveDrag(proposedTranscript: origin, total: 901), .collapse(.transcript))
        XCTAssertEqual(Split.resolveDrag(proposedTranscript: origin + 50, total: 901), .collapse(.transcript))
        XCTAssertEqual(Split.resolveDrag(proposedTranscript: origin + 100, total: 901), .resize(ratio: 200.0 / 900.0))
        XCTAssertEqual(Split.resolveDrag(proposedTranscript: origin + 300, total: 901), .resize(ratio: 324.0 / 900.0))
    }

    // MARK: - Opening a collapsed side

    func testArrowOpensEverythingWhenThereIsRoom() {
        XCTAssertNil(Split.expanded(opening: .comments, total: 901))
        XCTAssertNil(Split.expanded(opening: .transcript, total: 901))
    }

    func testArrowSwapsTheSidesWhenThereIsNoRoomForBoth() {
        XCTAssertEqual(Split.expanded(opening: .comments, total: 300), .transcript)
        XCTAssertEqual(Split.expanded(opening: .transcript, total: 300), .comments)
    }

    func testFocusingACommentOpensTheCommentsOnlyWhenTheyFit() {
        XCTAssertNil(Split.revealingComments(collapsed: .comments, total: 901))
        XCTAssertEqual(Split.revealingComments(collapsed: .comments, total: 300), .comments)
        XCTAssertEqual(Split.revealingComments(collapsed: .transcript, total: 901), .transcript)
        XCTAssertNil(Split.revealingComments(collapsed: nil, total: 901))
    }

    // MARK: - Remembered ratio

    func testSplitRatioPersistsInUserDefaults() {
        let settings = AppSettings.shared
        let original = settings.transcriptSplitRatio
        defer { settings.transcriptSplitRatio = original }
        settings.transcriptSplitRatio = 0.55
        XCTAssertEqual(AppSettings.sharedDefaults.double(forKey: "transcriptSplitRatio"), 0.55, accuracy: 1e-9)
    }
}

/// The floating Comment button: where it goes and when it shows.
final class CommentButtonPlacementTests: XCTestCase {
    private typealias Placement = CommentButtonPlacement
    private let pane = CGSize(width: 600, height: 400)

    func testSitsAboveTheSelectionsFirstLine() {
        let origin = Placement.origin(anchor: CGRect(x: 100, y: 100, width: 80, height: 20), in: pane)
        XCTAssertEqual(origin, CGPoint(x: 100, y: 100 - Placement.gap - Placement.size.height))
    }

    func testDropsBelowWhenThereIsNoRoomAbove() {
        let origin = Placement.origin(anchor: CGRect(x: 50, y: 10, width: 80, height: 20), in: pane)
        XCTAssertEqual(origin, CGPoint(x: 50, y: 10 + 20 + Placement.gap))
    }

    func testStaysInsideThePaneHorizontally() {
        let right = Placement.origin(anchor: CGRect(x: 590, y: 100, width: 5, height: 20), in: pane)
        XCTAssertEqual(right?.x, pane.width - Placement.size.width - Placement.margin)
        let left = Placement.origin(anchor: CGRect(x: -20, y: 100, width: 5, height: 20), in: pane)
        XCTAssertEqual(left?.x, Placement.margin)
    }

    func testStaysInsideThePaneVertically() {
        // A selection line at the very bottom, with no room above or below.
        let origin = Placement.origin(anchor: CGRect(x: 10, y: 20, width: 80, height: 370), in: pane)
        XCTAssertEqual(origin?.y, pane.height - Placement.size.height - Placement.margin)
    }

    func testHiddenWhenTheLineHasScrolledOutOfView() {
        XCTAssertNil(Placement.origin(anchor: CGRect(x: 0, y: -50, width: 80, height: 20), in: pane))
        XCTAssertNil(Placement.origin(anchor: CGRect(x: 0, y: 400, width: 80, height: 20), in: pane))
    }

    func testHiddenWhenThePaneCannotHoldIt() {
        XCTAssertNil(Placement.origin(anchor: CGRect(x: 0, y: 100, width: 10, height: 20), in: CGSize(width: 100, height: 400)))
    }

    func testVisibleOnlyForASelectionInASavedReadableTranscript() {
        XCTAssertTrue(Placement.isVisible(hasSelection: true, isDirty: false, isComposing: false, isReadable: true))
        XCTAssertFalse(Placement.isVisible(hasSelection: false, isDirty: false, isComposing: false, isReadable: true))
        XCTAssertFalse(Placement.isVisible(hasSelection: true, isDirty: true, isComposing: false, isReadable: true))
        XCTAssertFalse(Placement.isVisible(hasSelection: true, isDirty: false, isComposing: true, isReadable: true))
        XCTAssertFalse(Placement.isVisible(hasSelection: true, isDirty: false, isComposing: false, isReadable: false))
    }
}

/// The selection's first line, measured on a real text view.
final class TranscriptSelectionGeometryTests: XCTestCase {
    private func makeTextView() -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        textView.textContainerInset = NSSize(width: 10, height: 20)
        textView.string = "alpha beta gamma\ndelta epsilon zeta"
        return textView
    }

    func testReportsTheSelectedWordInsideTheTextInset() throws {
        let textView = makeTextView()
        let rect = try XCTUnwrap(TranscriptSelectionGeometry.firstLineRect(of: NSRange(location: 6, length: 4), in: textView))
        XCTAssertGreaterThan(rect.minX, 10, "after 'alpha ' on the first line")
        XCTAssertGreaterThanOrEqual(rect.minY, 20)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
    }

    func testASelectionAcrossLinesReportsOnlyItsFirstLine() throws {
        let textView = makeTextView()
        let single = try XCTUnwrap(TranscriptSelectionGeometry.firstLineRect(of: NSRange(location: 6, length: 4), in: textView))
        let multi = try XCTUnwrap(TranscriptSelectionGeometry.firstLineRect(of: NSRange(location: 6, length: 20), in: textView))
        XCTAssertEqual(multi.minX, single.minX, accuracy: 0.5)
        XCTAssertEqual(multi.minY, single.minY, accuracy: 0.5)
        XCTAssertEqual(multi.height, single.height, accuracy: 0.5)
    }

    func testALaterLineSitsLower() throws {
        let textView = makeTextView()
        let first = try XCTUnwrap(TranscriptSelectionGeometry.firstLineRect(of: NSRange(location: 0, length: 5), in: textView))
        let second = try XCTUnwrap(TranscriptSelectionGeometry.firstLineRect(of: NSRange(location: 17, length: 5), in: textView))
        XCTAssertGreaterThan(second.minY, first.maxY - 1)
    }

    func testNoRectForACaretOrAnOutOfRangeSelection() {
        let textView = makeTextView()
        XCTAssertNil(TranscriptSelectionGeometry.firstLineRect(of: NSRange(location: 3, length: 0), in: textView))
        XCTAssertNil(TranscriptSelectionGeometry.firstLineRect(of: NSRange(location: 30, length: 100), in: textView))
    }
}

/// The three places that used to tell the reader to comment are one: the
/// floating button.
final class CommentAffordanceTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
    }

    func testNoCommentOnSelectionWordingRemains() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if try String(contentsOf: url, encoding: .utf8).contains("Comment on selection") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testTheCommentsPaneHasNoEmptyStateAndFillsItsSlot() throws {
        let rail = try source("Views/CommentsRailView.swift")
        XCTAssertFalse(rail.contains("Select a passage"))
        XCTAssertFalse(rail.contains("comments.isEmpty"))
        XCTAssertFalse(rail.contains("maxWidth: 340"))
    }

    func testSessionViewUsesTheSplitAndTheFloatingButton() throws {
        let detail = try source("Views/SessionDetailView.swift")
        XCTAssertTrue(detail.contains("TranscriptSplitView("))
        XCTAssertTrue(detail.contains("hasComments: !comments.isEmpty"))
        XCTAssertTrue(detail.contains(".overlay { commentButtonOverlay }"))
        XCTAssertTrue(detail.contains("CommentButtonPlacement.isVisible("))
        XCTAssertTrue(detail.contains("onSelectionRectChange:"))
        // The bar above the transcript holds the edit controls only.
        XCTAssertTrue(detail.contains("if TranscriptEditBar.showsEditControls(isDirty: transcriptIsDirty) {"))
    }

    func testTheSplitHidesAndRevealsOnPolicy() throws {
        let view = try source("Views/TranscriptSplitView.swift")
        XCTAssertTrue(view.contains("TranscriptSplit.layout("))
        XCTAssertTrue(view.contains("TranscriptSplit.resolveDrag("))
        XCTAssertTrue(view.contains("TranscriptSplit.expanded("))
        XCTAssertTrue(view.contains("TranscriptSplit.revealingComments("))
    }
}
