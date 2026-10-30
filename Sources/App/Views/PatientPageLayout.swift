import CoreGraphics

/// How a patient's page splits between its session list and the open session.
enum PatientPageLayout {
    static let listMinWidth: CGFloat = 300
    static let sessionMinWidth: CGFloat = 360
    /// The line between the list and the session.
    static let dividerWidth: CGFloat = 1
    /// The list's share of the page until the divider is dragged: an even split.
    static let defaultListShare: Double = 0.5

    /// With no sessions there is nothing to open, so the list takes the page.
    static func showsSessionPane(sessionCount: Int) -> Bool { sessionCount > 0 }

    /// The list's width for a dragged-to `proposed` width in a page `total`
    /// wide: never under its minimum, and never so wide the session drops
    /// under its own.
    static func listWidth(proposed: CGFloat, total: CGFloat) -> CGFloat {
        max(listMinWidth, min(proposed, total - dividerWidth - sessionMinWidth))
    }

    /// The list's width when it keeps `share` of a page `total` wide.
    static func listWidth(share: Double, total: CGFloat) -> CGFloat {
        let share = share.isFinite && share > 0 && share < 1 ? share : defaultListShare
        return listWidth(proposed: (total - dividerWidth) * CGFloat(share), total: total)
    }

    /// The share of the page a list `width` wide keeps, so the split holds as
    /// the window resizes.
    static func share(listWidth width: CGFloat, total: CGFloat) -> Double {
        total > dividerWidth ? Double(width / (total - dividerWidth)) : defaultListShare
    }
}
