import AppKit
import SwiftUI

/// Aletheia keeps patient text out of system Writing Tools. Text that shows or
/// edits patient data goes through this kit (or `ThemeTextField` /
/// `ThemeTextArea`, built on it); `WritingToolsBlockTests` rejects the raw
/// SwiftUI and AppKit text APIs anywhere else.
extension NSTextView {
    /// Turns Writing Tools off on this text view.
    func disableWritingTools() {
        if #available(macOS 15, *) {
            writingToolsBehavior = .none
        }
    }
}

/// The base for every `NSTextView` in the app: Writing Tools are off however an
/// instance is created. Subclass this, not `NSTextView`.
class PatientTextView: NSTextView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disableWritingTools()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        disableWritingTools()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        disableWritingTools()
    }
}

@MainActor
extension TextField where Label == Text {
    /// A plain SwiftUI text field with Writing Tools off, for where
    /// `ThemeTextField`'s box doesn't fit (alerts, custom chrome). It returns
    /// the field itself, so alerts render it. Pass `focus` here rather than
    /// chaining `.focused`, so focus binds to the field inside the block.
    @ViewBuilder
    static func patient(_ title: String, text: Binding<String>, prompt: Text? = nil, focus: FocusState<Bool>.Binding? = nil) -> some View {
        if let focus {
            TextField(title, text: text, prompt: prompt).focused(focus).noWritingTools()
        } else {
            TextField(title, text: text, prompt: prompt).noWritingTools()
        }
    }
}

@MainActor
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

    /// Makes the text in this view selectable, with Writing Tools off.
    func selectablePatientText() -> some View {
        textSelection(.enabled).noWritingTools()
    }
}
