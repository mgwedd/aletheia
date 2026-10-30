import CoreGraphics

/// How a patient's page splits between its session list and the open session.
enum PatientPageLayout {
    static let listMinWidth: CGFloat = 300
    /// The list's width beside an open session until the divider is dragged:
    /// a compact column, so the session takes most of the page.
    static let defaultListWidth: CGFloat = 340
    static let sessionMinWidth: CGFloat = 360
    /// The line between the list and the session.
    static let dividerWidth: CGFloat = 1

    /// The session pane is there only while a session is open; otherwise the
    /// list takes the whole page.
    static func showsSessionPane(hasOpenSession: Bool) -> Bool { hasOpenSession }

    /// The list's width for a dragged-to `proposed` width in a page `total`
    /// wide: never under its minimum, and never so wide the session drops
    /// under its own. A page too narrow for both minimums is shared in their
    /// proportion, so the session never runs past the window.
    static func listWidth(proposed: CGFloat, total: CGFloat) -> CGFloat {
        let room = total - dividerWidth
        guard room >= listMinWidth + sessionMinWidth else {
            return max(0, room) * listMinWidth / (listMinWidth + sessionMinWidth)
        }
        let proposed = proposed.isFinite ? proposed : defaultListWidth
        return min(max(proposed, listMinWidth), room - sessionMinWidth)
    }
}
