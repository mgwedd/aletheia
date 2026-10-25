@testable import Aletheia
import Foundation
import SwiftUI
import XCTest

// MARK: - Subjects

/// A transcript with a session to comment on.
struct CommentedSession {
    let patient: Patient
    let session: SessionRecord
    let transcript: String
}

/// Where the floating Comment button lands for a selection.
struct FloatingCommentButton {
    let anchor: CGRect
    let pane: CGSize
    let origin: CGPoint?
    let visible: Bool
}

/// The comments rail for one session, as the data behind it reads.
struct CommentsRail {
    let comments: [SessionComment]
    var open: [SessionComment] { comments.filter { !$0.resolved } }
    var resolved: [SessionComment] { comments.filter(\.resolved) }
    /// "Resolved (N)" when anything is resolved.
    var resolvedHeading: String? { resolved.isEmpty ? nil : "Resolved (\(resolved.count))" }
}

/// A saved comment and where its passage sits in the transcript.
struct PlacedComment {
    let comment: SessionComment
    let spans: [TranscriptHighlighter.Span]
    let transcript: String
}

/// What the split looks like for a pane width.
struct SplitView {
    let paneWidth: CGFloat
    let layout: TranscriptSplit.Layout
}

// MARK: - Given

extension Given {
    /// A session whose transcript has a few lines to comment on.
    func transcribedSession(for name: String = "Jane Doe") async throws -> CommentedSession {
        let patient = try await self.patient(named: name)
        let session = try XCTUnwrap(app.appModel.startNewSession(for: patient))
        let transcript = """
        [00:00] Therapist: How has the week been?
        [00:12] Client: \(Copy.commentPassage) It keeps coming up.
        [00:40] Therapist: What makes it hard?
        """
        try XCTUnwrap(app.appModel.store).saveTranscript(transcript, for: patient, session: session)
        return CommentedSession(patient: patient, session: session, transcript: transcript)
    }
}

// MARK: - When

extension When {
    /// Selects a few words partway down the transcript pane.
    func selectAFewWords() -> FloatingCommentButton {
        let anchor = CGRect(x: 120, y: 200, width: 160, height: 18)
        let paneSize = CGSize(width: 600, height: 500)
        return FloatingCommentButton(
            anchor: anchor, pane: paneSize,
            origin: CommentButtonPlacement.origin(anchor: anchor, in: paneSize),
            visible: CommentButtonPlacement.isVisible(
                hasSelection: true, isDirty: false, isComposing: false, isReadable: true))
    }

    /// Selects `quote` in the transcript and saves a comment on it, as the composer does.
    @discardableResult
    func comment(on quote: String, saying body: String, in subject: CommentedSession) throws -> PlacedComment {
        let text = subject.transcript as NSString
        let range = text.range(of: quote)
        XCTAssertNotEqual(range.location, NSNotFound, "quote is not in the transcript")
        let seconds = TranscriptTimeline.seconds(atOffset: range.location, in: subject.transcript)
        let comment = try XCTUnwrap(
            app.appModel.addComment(
                sessionID: subject.session.id, quotedText: quote, body: body,
                anchorSeconds: seconds.map(Double.init), quoteStart: range.location),
            "the comment was not saved")
        return place(comment, in: subject.transcript)
    }

    func place(_ comment: SessionComment, in transcript: String) -> PlacedComment {
        let spans = TranscriptHighlighter.spans(
            in: transcript, comments: [(id: comment.id, quote: comment.quotedText, start: comment.quoteStart)])
        return PlacedComment(comment: comment, spans: spans, transcript: transcript)
    }

    func lookAtCommentsRail(of subject: CommentedSession) throws -> CommentsRail {
        CommentsRail(comments: try XCTUnwrap(app.appModel.store).comments(for: subject.session))
    }

    func edit(_ comment: SessionComment, to body: String) {
        app.appModel.updateComment(id: comment.id, body: body)
    }

    func resolve(_ comment: SessionComment) { app.appModel.setCommentResolved(id: comment.id, resolved: true) }
    func reopen(_ comment: SessionComment) { app.appModel.setCommentResolved(id: comment.id, resolved: false) }

    /// Clicks Delete on a comment's card. There is no confirmation step to answer.
    func delete(_ comment: SessionComment) {
        app.appModel.commentStore?.deleteComment(id: comment.id)
    }

    /// Drags the divider so the transcript takes `fraction` of the window width.
    func deletePatient(_ subject: CommentedSession) throws {
        try app.appModel.deletePatient(subject.patient)
    }

    func dragDivider(toFraction fraction: Double) -> TranscriptSplit.DragResult {
        let result = TranscriptSplit.resolveDrag(proposedTranscript: Self.paneWidth * fraction, total: Self.paneWidth)
        if case .resize(let ratio) = result { app.settings.transcriptSplitRatio = ratio }
        return result
    }

    func dragDividerFarLeft() -> TranscriptSplit.DragResult {
        TranscriptSplit.resolveDrag(proposedTranscript: 40, total: Self.paneWidth)
    }

    func dragDividerFarRight() -> TranscriptSplit.DragResult {
        TranscriptSplit.resolveDrag(proposedTranscript: Self.paneWidth - 20, total: Self.paneWidth)
    }

    func lookAtSplit() -> SplitView {
        SplitView(
            paneWidth: Self.paneWidth,
            layout: TranscriptSplit.layout(
                total: Self.paneWidth, ratio: app.settings.transcriptSplitRatio, hasComments: true, collapsed: nil))
    }

    private static let paneWidth: CGFloat = 900

    /// Clicks the character at `offset` in the transcript.
    func clickTranscript(at offset: Int, placed: PlacedComment) -> String? {
        TranscriptHighlighter.commentID(at: offset, in: placed.spans)
    }
}

// MARK: - Then

extension Then where Subject == FloatingCommentButton {
    func sitsJustAboveSelection() {
        guard let origin = subject.origin else { return fail("expected the Comment button to be placed, it was not") }
        expectEqual(origin.y, subject.anchor.minY - CommentButtonPlacement.gap - CommentButtonPlacement.size.height,
                    "the button's top edge (just above the selection)")
        expectEqual(origin.x, subject.anchor.minX, "the button's left edge (the selection's start)")
    }

    func isShown() { expect(subject.visible, "expected the Comment button to show for a selection") }
}

extension Then where Subject == CommentsRail {
    func listsOpen(_ bodies: [String]) { expectEqual(subject.open.map(\.body), bodies, "the open cards") }
    func hasResolvedSection(_ heading: String) { expectEqual(subject.resolvedHeading, heading, "the resolved section") }
    func hasNoResolvedSection() { expectEqual(subject.resolvedHeading, nil, "the resolved section") }
    func hasNoCards() { expect(subject.comments.isEmpty, "expected no cards, found \(subject.comments.map(\.body))") }
    func hasResolved(_ bodies: [String]) { expectEqual(subject.resolved.map(\.body), bodies, "the resolved cards") }
}

extension Then where Subject == PlacedComment {
    func cardShowsQuote(_ quote: String) { expectEqual(subject.comment.quotedText, quote, "the card's quote") }

    func highlightsPassage(_ quote: String) {
        guard let span = subject.spans.first else { return fail("expected the passage to be highlighted, found no highlight") }
        expectEqual((subject.transcript as NSString).substring(with: span.range), quote, "the highlighted text")
    }

    func clickingPassageFocusesThisCard() {
        let offset = (subject.comment.quoteStart ?? 0) + 5
        let id = TranscriptHighlighter.commentID(at: offset, in: subject.spans)
        expectEqual(id, subject.comment.id, "the card focused by a click in the passage")
        let focus = TranscriptFocus.comment(subject.comment.id)
        let length = (subject.transcript as NSString).length
        expect(TranscriptHighlighter.range(for: focus, spans: subject.spans, length: length) != nil,
               "expected the passage to be scrolled into view")
        expect(TranscriptHighlighter.isNewFocusRequest(focus, token: 1, lastHandledToken: nil),
               "expected the click to count as a new focus request")
    }
}

extension Then where Subject == TranscriptSplit.DragResult {
    func resizes() {
        if case .resize = subject { return }
        fail("expected the divider drag to resize the split, found \(subject)")
    }

    func foldsAwayTranscript() { expectEqual(subject, .collapse(.transcript), "the drag result") }
    func foldsAwayComments() { expectEqual(subject, .collapse(.comments), "the drag result") }
}

extension Then where Subject == SplitView {
    func transcriptTakes(_ fraction: Double) {
        let usable = subject.paneWidth - TranscriptSplit.dividerWidth
        expectEqual(subject.layout.transcript, (usable * CGFloat(fraction)).rounded(), "the transcript width")
        expectEqual(subject.layout.comments, usable - subject.layout.transcript, "the comments width")
    }
}
