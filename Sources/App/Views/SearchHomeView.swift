import AppKit
import SwiftUI

/// The detail pane while no patient is open: global search as the home screen.
/// A large field bound to the same `GlobalSearchModel` as the sidebar's, so
/// typing in either shows the same results, which render here in place.
///
///        [🔍 Search all patients, sessions and notes   ⌘ F]
struct SearchHomeView: View {
    @ObservedObject var model: GlobalSearchModel
    let onOpen: (SearchHit) -> Void
    var sidebarHidden = false
    var onShowSidebar: () -> Void = {}
    @FocusState private var focused: Bool

    static let hiddenHint = "or show the sidebar to choose a patient"

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasQuery { Spacer(minLength: 0) }
            // One field in every state, so typing the first letter keeps the cursor in it.
            GlobalSearchField(
                model: model, isFocused: $focused, onOpen: onOpen,
                placeholder: GlobalSearchField.homePrompt, large: true
            )
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.vertical, model.hasQuery ? 16 : 6)
            if model.hasQuery {
                GlobalSearchResultsView(model: model, onOpen: onOpen)
            } else {
                if sidebarHidden {
                    Button(action: onShowSidebar) {
                        Label(Self.hiddenHint, systemImage: "sidebar.leading")
                    }
                    .buttonStyle(.themed)
                    .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window.color)
        .onAppear {
            // Unless the cursor is already in another text field.
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor { return }
            DispatchQueue.main.async { focused = true }
        }
    }
}
