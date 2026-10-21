import SwiftUI

enum BoundedScrollLayout {
    /// What a `BoundedScroll` reports as its natural height, whatever it holds.
    static let idealHeight: CGFloat = 240
}

/// A vertical `ScrollView` that fills the space it is given but does not ask
/// for its content's height. A bare `ScrollView` reports its content's full
/// height as its ideal one, so a long note could make the window grow to fit
/// all of it, past the screen: the scroll view then fits its content exactly
/// and has nothing to scroll.
struct BoundedScroll<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView { content }
            .frame(minHeight: 0, idealHeight: BoundedScrollLayout.idealHeight, maxHeight: .infinity)
    }
}
