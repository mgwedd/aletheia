import AppKit
import SwiftUI

/// The one search field, at the foot of the patient sidebar so it reads as
/// searching everything, not the open session: patients by name, sessions by
/// date, and every note, comment and transcript. Results show over the detail
/// pane (`GlobalSearchResultsView`) while there is a query. The field keeps
/// the keyboard the whole time: up/down move through the results, Return opens
/// one, esc clears the query (and, when empty, leaves the field). ⌘F focuses it.
///
///   [🔍 Search all patients ...............]
struct GlobalSearchField: View {
    @ObservedObject var model: GlobalSearchModel
    var isFocused: FocusState<Bool>.Binding
    let onOpen: (SearchHit) -> Void

    static let prompt = "Search all patients"
    /// The large field on the empty detail pane (`SearchHomeView`).
    static let homePrompt = "Search all patients, sessions and notes"

    var placeholder = GlobalSearchField.prompt
    var large = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: large ? 16 : 12, weight: .medium))
                .foregroundStyle(Theme.muted.color)
                .accessibilityHidden(true)

            TextField.patient(placeholder, text: $model.query, prompt: Text(placeholder).foregroundStyle(Theme.muted.color), focus: isFocused)
                .textFieldStyle(.plain)
                .font(large ? Theme.Typography.headline : Theme.Typography.body)
                .foregroundStyle(Theme.text.color)
                .accessibilityLabel("Search everything")
                .accessibilityHint("Searches names, session dates, notes, comments and transcripts. Up and down arrows move through the results; Return opens one.")
                .onKeyPress(.upArrow) { model.move(by: -1) ? .handled : .ignored }
                .onKeyPress(.downArrow) { model.move(by: 1) ? .handled : .ignored }
                .onKeyPress(.return) { activateSelection() }
                .onKeyPress(.escape) { escape() }
                .onSubmit { _ = activateSelection() }

            trailing
        }
        .padding(.horizontal, large ? 14 : 8)
        .frame(maxWidth: .infinity, minHeight: large ? 44 : 28, maxHeight: large ? 44 : 28)
        .themeField(isFocused: isFocused.wrappedValue)
        .help(ShortcutGlyphs.help("Search names, sessions, notes, comments and transcripts", AppHotkey.search))
    }

    @ViewBuilder
    private var trailing: some View {
        if model.query.isEmpty {
            // Only the large field has room for the keycaps; in the sidebar they
            // squeeze the placeholder, and the tooltip names ⌘F.
            if large {
                ShortcutHint(AppHotkey.search)
                    .opacity(isFocused.wrappedValue ? 0 : 1)
            }
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

/// Carries ⌘F for the window. Invisible: the field is what it focuses.
/// ⌘F is always the global search, wherever the cursor is, including in a
/// transcript or note; the text's own find bar is on ⌥⌘F.
///
/// It listens for the key itself rather than through SwiftUI's
/// `keyboardShortcut`: while an AppKit text view (the transcript, a note) has
/// the cursor, that view claims ⌘F for its find bar and SwiftUI never sees it.
struct GlobalSearchHotkey: NSViewRepresentable {
    var isFocused: FocusState<Bool>.Binding

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let binding = isFocused
        context.coordinator.focusSearch = { [weak view] in
            // SwiftUI's focus doesn't take the cursor from an AppKit text view, so
            // release it first, and toggle the state so a stale `true` re-focuses.
            view?.window?.makeFirstResponder(nil)
            binding.wrappedValue = false
            DispatchQueue.main.async { binding.wrappedValue = true }
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var focusSearch: () -> Void = {}
        private var monitor: Any?

        func attach(to view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard let self, let window = view?.window, event.window === window else { return event }
                // Local monitors run on the main thread.
                return MainActor.assumeIsolated {
                    switch GlobalSearchShortcut.route(event, firstResponder: window.firstResponder) {
                    case .focusSearch:
                        self.focusSearch()
                        return nil
                    case .showFindBar(let textView):
                        GlobalSearchShortcut.showFindBar(in: textView)
                        return nil
                    case .passThrough:
                        return event
                    }
                }
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { detach() }
    }
}

