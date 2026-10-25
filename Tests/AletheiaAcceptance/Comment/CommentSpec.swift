import XCTest

final class CommentSpec: AcceptanceCase {
    func test_COMMENT_01() async throws {
        let button = when.selectAFewWords()

        then(button).isShown()
        then(button).sitsJustAboveSelection()
    }

    func test_COMMENT_02() async throws {
        try pending("UI driver: the \u{2325}\u{2318}M binding and the composer's quote and Save comment enabled state are private view code (SessionDetailView, InlineCommentComposerCard)")
    }

    func test_COMMENT_03() async throws {
        let subject = try await given.transcribedSession()

        let placed = try when.comment(on: Copy.commentPassage, saying: "Explore the avoidance", in: subject)

        then(try when.lookAtCommentsRail(of: subject)).listsOpen(["Explore the avoidance"])
        then(placed).cardShowsQuote(Copy.commentPassage)
        then(placed).highlightsPassage(Copy.commentPassage)
    }

    func test_COMMENT_04() async throws {
        let subject = try await given.transcribedSession()
        let placed = try when.comment(on: Copy.commentPassage, saying: "Explore the avoidance", in: subject)

        then(placed).clickingPassageFocusesThisCard()
    }

    func test_COMMENT_05() async throws {
        then(when.dragDivider(toFraction: 0.5)).resizes()

        given.appRelaunched()

        then(when.lookAtSplit()).transcriptTakes(0.5)
        then(when.dragDividerFarLeft()).foldsAwayTranscript()
        then(when.dragDividerFarRight()).foldsAwayComments()
    }

    func test_COMMENT_06() async throws {
        let subject = try await given.transcribedSession()
        let placed = try when.comment(on: Copy.commentPassage, saying: "First thought", in: subject)

        when.edit(placed.comment, to: "Revised thought")
        when.resolve(placed.comment)
        let resolved = try when.lookAtCommentsRail(of: subject)
        then(resolved).listsOpen([])
        then(resolved).hasResolved(["Revised thought"])
        then(resolved).hasResolvedSection("Resolved (1)")

        when.reopen(placed.comment)
        let reopened = try when.lookAtCommentsRail(of: subject)
        then(reopened).listsOpen(["Revised thought"])
        then(reopened).hasNoResolvedSection()
    }

    func test_COMMENT_07() async throws {
        let subject = try await given.transcribedSession()
        let placed = try when.comment(on: Copy.commentPassage, saying: "Explore the avoidance", in: subject)

        when.delete(placed.comment)

        then(try when.lookAtCommentsRail(of: subject)).hasNoCards()
    }

    func test_COMMENT_08() async throws {
        let subject = try await given.transcribedSession()
        try when.comment(on: Copy.commentPassage, saying: "Explore the avoidance", in: subject)

        try when.deletePatient(subject)

        then(try when.lookAtCommentsRail(of: subject)).hasNoCards()
    }
}
