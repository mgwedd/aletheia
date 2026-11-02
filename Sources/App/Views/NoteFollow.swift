import CoreGraphics

/// Whether the note reader keeps the newest text in view while a note is
/// written. It follows until the therapist scrolls up, follows again once they
/// scroll back to the end, and goes to the end when the writing stops. Pure, so
/// it is tested without a view.
struct NoteFollow: Equatable {
    /// How far from the end still counts as at the end: about two lines of note text.
    static let nearEnd: CGFloat = 40

    private(set) var isFollowing = true
    private var wasWriting = false

    /// The therapist scrolled, leaving the bottom of the view `distanceFromEnd`
    /// points above the end of the note.
    mutating func scrolled(distanceFromEnd: CGFloat) {
        isFollowing = distanceFromEnd <= Self.nearEnd
    }

    /// The reader updated: whether to scroll to the end. A note that starts is
    /// followed afresh; new text scrolls only while following; the writing
    /// stopping always goes to the end.
    mutating func update(writing: Bool, textGrew: Bool) -> Bool {
        defer { wasWriting = writing }
        if writing && !wasWriting { isFollowing = true }
        if wasWriting && !writing { return true }
        return writing && textGrew && isFollowing
    }
}
