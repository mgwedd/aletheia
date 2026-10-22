import AppKit
import SwiftUI

/// Aletheia keeps patient text out of system Writing Tools. Every text surface
/// that shows or edits patient data uses one of these two helpers; a source
/// test (`WritingToolsBlockTests`) fails when a new field forgets to.
extension NSTextView {
    /// Turns Writing Tools off on this text view. Call it from the subclass
    /// initializer so every instance, however it is created, is covered.
    func disableWritingTools() {
        if #available(macOS 15, *) {
            writingToolsBehavior = .none
        }
    }
}

extension View {
    /// Turns Writing Tools off for this view and its descendants (SwiftUI
    /// text fields edit through an `NSTextView` field editor).
    @ViewBuilder
    func noWritingTools() -> some View {
        if #available(macOS 15, *) {
            writingToolsBehavior(.disabled)
        } else {
            self
        }
    }
}
