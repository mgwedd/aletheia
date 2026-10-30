import CoreGraphics

/// How a patient's page splits between its session list and the open session.
enum PatientPageLayout {
    static let listMinWidth: CGFloat = 300
    static let listIdealWidth: CGFloat = 380
    static let listMaxWidth: CGFloat = 640
    static let sessionMinWidth: CGFloat = 360

    /// With no sessions there is nothing to open, so the list takes the page.
    static func showsSessionPane(sessionCount: Int) -> Bool { sessionCount > 0 }

    /// The list's width for a dragged-to `proposed` width in a page `total`
    /// wide: never under its minimum, and never so wide the session drops
    /// under its own.
    static func listWidth(proposed: CGFloat, total: CGFloat) -> CGFloat {
        let upper = min(listMaxWidth, total - sessionMinWidth)
        return max(listMinWidth, min(proposed, upper))
    }
}
