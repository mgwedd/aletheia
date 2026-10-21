import AppKit
import SwiftUI

/// The one search field, at the top right of the main window: patients by
/// name, sessions by date, and every note, comment and transcript. Results
/// show over the detail pane (`GlobalSearchResultsView`) while there is a
/// query. The field keeps the keyboard the whole time: up/down move through
/// the results, Return opens one, esc clears the query (and, when empty,
/// leaves the field). ⌘F focuses it.
///
///   [🔍 Search ............................ ⌘ F]
struct GlobalSearchField: View {
    @ObservedObject var model: GlobalSearchModel
    var isFocused: FocusState<Bool>.Binding
    let onOpen: (SearchHit) -> Void

    static let width: CGFloat = 280

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted.color)
                .accessibilityHidden(true)

            TextField("Search", text: $model.query, prompt: Text("Search").foregroundStyle(Theme.muted.color))
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.text.color)
                .focused(isFocused)
                .accessibilityLabel("Search everything")
                .accessibilityHint("Searches names, session dates, notes, comments and transcripts. Up and down arrows move through the results; Return opens one.")
                .onKeyPress(.upArrow) { model.move(by: -1) ? .handled : .ignored }
                .onKeyPress(.downArrow) { model.move(by: 1) ? .handled : .ignored }
                .onKeyPress(.return) { activateSelection() }
                .onKeyPress(.escape) { escape() }
                .onSubmit { _ = activateSelection() }

            trailing
        }
        .padding(.horizontal, 8)
        .frame(width: Self.width, height: 28)
        .themeField(isFocused: isFocused.wrappedValue)
        .help(ShortcutGlyphs.help("Search names, sessions, notes, comments and transcripts", AppHotkey.search))
    }

    @ViewBuilder
    private var trailing: some View {
        if model.query.isEmpty {
            ShortcutHint(AppHotkey.search)
                .opacity(isFocused.wrappedValue ? 0 : 1)
        } else {
            Button {
                model.clear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted.color)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear search")
            .help(ShortcutGlyphs.help("Clear the search", .cancelAction))
        }
    }

    private func activateSelection() -> KeyPress.Result {
        guard let activation = model.activate() else { return .ignored }
        if case .open(let hit) = activation { onOpen(hit) }
        return .handled
    }

    private func escape() -> KeyPress.Result {
        if model.query.isEmpty {
            isFocused.wrappedValue = false
        } else {
            model.clear()
        }
        return .handled
    }

}

/// Carries ⌘F for the window (outside the toolbar, which can push the field
/// into its overflow menu). Invisible: the field is what it focuses.
struct GlobalSearchHotkey: View {
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        Button(action: focusOrFind) { EmptyView() }
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .shortcut(AppHotkey.search, help: "Search everything")
            .accessibilityHidden(true)
    }

    /// ⌘F while the cursor is in a transcript or note opens that text's find
    /// bar, as it did before; anywhere else it focuses the search field.
    private func focusOrFind() {
        if let textView = GlobalSearchShortcut.findableTextView(NSApp.keyWindow?.firstResponder) {
            GlobalSearchShortcut.showFindBar(in: textView)
        } else {
            isFocused.wrappedValue = true
        }
    }
}
