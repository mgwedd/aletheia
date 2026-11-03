import AppKit
import SwiftUI

enum BoundedScrollLayout {
    /// What a `BoundedScroll` reports as its natural height, whatever it holds.
    static let idealHeight: CGFloat = 240

    /// The width a scroller takes from the content beside it: a legacy
    /// scroller (shown when a mouse, not a trackpad, is in use, or by the
    /// "Show scroll bars: Always" setting) takes its own width; an overlay
    /// scroller floats over the content and takes none.
    static func scrollerGutter(style: NSScroller.Style = NSScroller.preferredScrollerStyle) -> CGFloat {
        style == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}

/// A vertical `ScrollView` that fills the space it is given but does not ask
/// for its content's height. A bare `ScrollView` reports its content's full
/// height as its ideal one, so a long note could make the window grow to fit
/// all of it, past the screen: the scroll view then fits its content exactly
/// and has nothing to scroll.
///
/// Its content always leaves room for the scroller, so it keeps its width when
/// the content grows long enough to scroll and a legacy scroller appears;
/// otherwise every line rewraps at that moment.
struct BoundedScroll<Content: View>: View {
    private let content: Content
    @State private var width: CGFloat?
    @State private var gutter = BoundedScrollLayout.scrollerGutter()

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content.frame(width: width.map { max(0, $0 - gutter) }, alignment: .leading)
        }
        .frame(minHeight: 0, idealHeight: BoundedScrollLayout.idealHeight, maxHeight: .infinity)
        .background(GeometryReader { Color.clear.preference(key: BoundedScrollWidth.self, value: $0.size.width) })
        .onPreferenceChange(BoundedScrollWidth.self) { width = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            gutter = BoundedScrollLayout.scrollerGutter()
        }
    }
}

/// The scroll view's own width, scroller included.
private struct BoundedScrollWidth: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}
