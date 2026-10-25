import AppKit
import SwiftUI

/// One selectable row of the search results: a hit, or a group's "Show more".
enum GlobalSearchRow: Equatable, Identifiable {
    case hit(SearchHit)
    /// Shows more of the group; `hidden` matches are not shown yet.
    case more(SearchKind, hidden: Int)

    var id: String {
        switch self {
        case .hit(let hit): return hit.id
        case .more(let kind, _): return "more-\(kind.rawValue)"
        }
    }

    /// The rows in the order shown: each group's hits, then its "Show more"
    /// while it can still grow.
    static func rows(for results: GlobalSearchResults, limits: GlobalSearchLimits) -> [GlobalSearchRow] {
        var rows: [GlobalSearchRow] = []
        for section in results.sections {
            for hit in section.hits { rows.append(.hit(hit)) }
            if let more = more(for: section, limits: limits) { rows.append(more) }
        }
        return rows
    }

    /// The group's "Show more" row, nil when everything is shown or it is at the maximum.
    static func more(for section: GlobalSearchSection, limits: GlobalSearchLimits) -> GlobalSearchRow? {
        guard section.hiddenCount > 0, limits.limit(for: section.kind) < GlobalSearchLimits.maximum else { return nil }
        return .more(section.kind, hidden: section.hiddenCount)
    }

    /// The row `delta` rows from `current`, stopping at the first and last. With
    /// nothing selected, down picks the first row and up the last.
    static func move(from current: String?, by delta: Int, in rows: [GlobalSearchRow]) -> String? {
        guard !rows.isEmpty else { return nil }
        guard let current, let at = rows.firstIndex(where: { $0.id == current }) else {
            return delta < 0 ? rows[rows.count - 1].id : rows[0].id
        }
        let next = min(max(at + delta, 0), rows.count - 1)
        return rows[next].id
    }

    /// "Show 25 more of 395" (or "Show 3 more" when that's all of them).
    static func moreTitle(hidden: Int) -> String {
        let next = min(hidden, GlobalSearchLimits.step)
        return next == hidden ? "Show \(next) more" : "Show \(next) more of \(hidden)"
    }

    /// Under a group that shows the most it can and still has more.
    static func cappedNote(for section: GlobalSearchSection, limits: GlobalSearchLimits) -> String? {
        guard section.hiddenCount > 0, limits.limit(for: section.kind) >= GlobalSearchLimits.maximum else { return nil }
        return "Showing the first \(section.hits.count) of \(section.total). Add a word to narrow the search."
    }

    /// What the results area says when nothing matched.
    static func emptyMessage(query: String, results: GlobalSearchResults) -> String {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return results.coverage.isComplete ? "No results for \u{201C}\(typed)\u{201D}" : "No results yet for \u{201C}\(typed)\u{201D}"
    }
}

/// What VoiceOver announces when the results change.
enum GlobalSearchAnnouncement {
    static func text(for results: GlobalSearchResults) -> String {
        var text: String
        if results.total == 0 {
            text = "No results"
        } else {
            let noun = results.total == 1 ? "result" : "results"
            let groups = results.sections.count == 1 ? "1 group" : "\(results.sections.count) groups"
            text = "\(results.total) \(noun) in \(groups)"
        }
        if let status = results.coverage.statusText { text += ". " + status }
        return text
    }
}

/// Where opening a result goes: the patient, and for anything inside a
/// session that session, on the tab (and note format, My Notes, or comment)
/// the match is in, and for a transcript or note the passage to scroll to.
struct SearchHitDestination: Equatable {
    let patientID: UUID
    let sessionID: UUID?
    let tab: SessionTab?
    let noteFormat: ProgressNoteFormat?
    let showingMyNotes: Bool
    let commentID: String?
    /// The transcript line or note paragraph that matched (see `SearchMatchFocus`).
    let matchPassage: Int?

    init(_ hit: SearchHit) {
        patientID = hit.patient.id
        sessionID = hit.session?.id
        guard hit.session != nil else {
            tab = nil
            noteFormat = nil
            showingMyNotes = false
            commentID = nil
            matchPassage = nil
            return
        }
        switch hit.kind {
        case .note:
            tab = .notes
            noteFormat = hit.noteFormat
            showingMyNotes = false
            commentID = nil
            matchPassage = hit.passage
        case .sessionNotes:
            tab = .notes
            noteFormat = nil
            showingMyNotes = true
            commentID = nil
            matchPassage = nil
        case .comment:
            tab = .transcript
            noteFormat = nil
            showingMyNotes = false
            commentID = hit.commentID
            matchPassage = nil
        case .transcript:
            tab = .transcript
            noteFormat = nil
            showingMyNotes = false
            commentID = nil
            matchPassage = hit.passage
        case .session, .patient:
            tab = .transcript
            noteFormat = nil
            showingMyNotes = false
            commentID = nil
            matchPassage = nil
        }
    }

    /// What to scroll to and flash once the session is open, for `query`.
    func searchFocus(query: String) -> SearchMatchFocus? {
        matchPassage.map { SearchMatchFocus(query: query, passage: $0) }
    }
}

/// ⌥⌘F: the find bar of the transcript or note that has the cursor (⌘F is
/// always the global search).
enum GlobalSearchShortcut {
    /// Plain ⌘F, the key a text view's find bar would otherwise claim.
    static func isGlobalSearch(_ event: NSEvent) -> Bool {
        isF(event, modifiers: .command)
    }

    /// What a key press does while `firstResponder` holds the cursor: ⌘F focuses the
    /// sidebar search wherever the cursor is; ⌥⌘F opens the find bar of a transcript
    /// or note; anything else is left alone.
    @MainActor
    static func route(_ event: NSEvent, firstResponder: NSResponder?) -> Route {
        if isGlobalSearch(event) { return .focusSearch }
        if isFindInText(event), let textView = findableTextView(firstResponder) { return .showFindBar(textView) }
        return .passThrough
    }

    enum Route {
        case focusSearch
        case showFindBar(NSTextView)
        case passThrough
    }

    /// ⌥⌘F.
    static func isFindInText(_ event: NSEvent) -> Bool {
        isF(event, modifiers: [.command, .option])
    }

    private static func isF(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        event.type == .keyDown
            && event.modifierFlags.intersection([.command, .shift, .option, .control]) == modifiers
            && event.charactersIgnoringModifiers?.lowercased() == "f"
    }

    /// The responder if it is a text view with its own find bar (the transcript
    /// or a note), not the editor of a text field such as the search field.
    @MainActor
    static func findableTextView(_ responder: NSResponder?) -> NSTextView? {
        guard let textView = responder as? NSTextView, textView.usesFindBar, !textView.isFieldEditor else { return nil }
        return textView
    }

    @MainActor
    static func showFindBar(in textView: NSTextView) {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }
}

/// The state behind the search field and its results: the query, the results,
/// which row is selected, and how many of each group to show. The search
/// itself runs off the main actor (see `run(store:)`).
@MainActor
final class GlobalSearchModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { limits = GlobalSearchLimits() } }
    }
    @Published private(set) var results = GlobalSearchResults.empty
    @Published private(set) var selectedID: String?
    @Published private(set) var limits = GlobalSearchLimits()

    /// How long typing must pause before the search runs.
    let debounceNanoseconds: UInt64
    /// After "Show more": select the first of the newly shown hits.
    private var expandAnchor: (kind: SearchKind, shown: Int)?

    init(debounceNanoseconds: UInt64 = 150_000_000) {
        self.debounceNanoseconds = debounceNanoseconds
    }

    /// Whether there is anything to search for (results are shown only then).
    var hasQuery: Bool { !GlobalSearchQuery(query).isEmpty }

    var rows: [GlobalSearchRow] { GlobalSearchRow.rows(for: results, limits: limits) }

    /// Runs the search for the current query once typing has paused. The
    /// caller's task is cancelled when the query, the limits or the index
    /// change (`.task(id:)`), which stops the search too.
    func run(store: Store?) async {
        guard hasQuery, let store else {
            results = .empty
            selectedID = nil
            return
        }
        if debounceNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
        }
        guard !Task.isCancelled else { return }
        let typed = query
        let limits = self.limits
        let search = Task.detached(priority: .userInitiated) {
            store.globalSearch(query: typed, limits: limits, shouldContinue: { !Task.isCancelled })
        }
        let found = await withTaskCancellationHandler { await search.value } onCancel: { search.cancel() }
        guard !Task.isCancelled else { return }
        show(found)
    }

    /// Shows new results, keeping the selected row when it is still there.
    func show(_ found: GlobalSearchResults) {
        results = found
        let rows = self.rows
        if let anchor = expandAnchor {
            expandAnchor = nil
            if let section = found.section(anchor.kind), anchor.shown < section.hits.count {
                selectedID = section.hits[anchor.shown].id
                return
            }
        }
        if let selectedID, rows.contains(where: { $0.id == selectedID }) { return }
        selectedID = rows.first?.id
    }

    /// Moves the selection; false when there is nothing to move through.
    @discardableResult
    func move(by delta: Int) -> Bool {
        let rows = self.rows
        guard !rows.isEmpty else { return false }
        selectedID = GlobalSearchRow.move(from: selectedID, by: delta, in: rows)
        return true
    }

    func select(_ id: String) {
        selectedID = id
    }

    enum Activation: Equatable {
        case open(SearchHit)
        case expanded(SearchKind)
    }

    /// Return on a row (the selected one by default): a hit is opened by the
    /// caller; "Show more" shows `GlobalSearchLimits.step` more of its group.
    func activate(_ id: String? = nil) -> Activation? {
        guard let target = id ?? selectedID, let row = rows.first(where: { $0.id == target }) else { return nil }
        switch row {
        case .hit(let hit):
            return .open(hit)
        case .more(let kind, _):
            selectedID = target
            expandAnchor = (kind: kind, shown: results.section(kind)?.hits.count ?? 0)
            limits.showMore(of: kind)
            return .expanded(kind)
        }
    }

    func clear() {
        query = ""
        results = .empty
        selectedID = nil
        expandAnchor = nil
    }
}
