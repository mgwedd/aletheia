import SwiftUI

/// Search across every patient's name, transcripts, notes, session notes and
/// comments, as one flat list. The text field keeps focus the whole time:
/// up/down move the selection, return opens it. Opening a result closes the
/// sheet, selects the patient and, for anything inside a session, that session.
///
///   ┌ 🔍 query ........................................ [esc] ┐
///   │ (All 5) Patients 0  Sessions 1  Transcripts 2 …          │
///   │ ┌ Transcript  Test Patient, Oct 8, 2026                ┐ │
///   │ └             [00:57] … couples therapy …              ┘ │
///   │ N results across M patients.        [↑][↓] move [return] │
///   └──────────────────────────────────────────────────────────┘
struct GlobalSearchView: View {
    @EnvironmentObject private var appModel: AppModel
    /// Called with the patient, and the session when the result is inside one.
    let onOpen: (Patient, SessionRecord?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    /// nil is "All".
    @State private var filter: SearchKind?
    @State private var selectedID: String?
    @State private var listContentHeight: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    /// How long typing must pause before the search runs.
    private static let debounceNanoseconds: UInt64 = 150_000_000
    private static let listMaxHeight: CGFloat = 400
    private static let listMinHeight: CGFloat = 140

    private var hasQuery: Bool { !TextSearch.queryTerms(query).isEmpty }

    private var visibleHits: [SearchHit] {
        guard let filter else { return hits }
        return hits.filter { $0.kind == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            fieldRow
                .frame(height: 54)
                .themeDivider(.bottom)

            filterRow
                .themeDivider(.bottom)

            resultsArea

            footer
                .themeDivider(.top)
        }
        .frame(width: 680)
        .frame(maxHeight: 560)
        .background(Theme.panel.color)
        .defaultFocus($fieldFocused, true)
        .onAppear { fieldFocused = true }
        .task(id: query) { await runSearch() }
        .onChange(of: filter) { _, _ in selectedID = visibleHits.first?.id }
    }

    // MARK: Field

    private var fieldRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Theme.muted.color)
                .accessibilityHidden(true)

            TextField("Search", text: $query, prompt: Text("Search names, transcripts, notes and comments").foregroundStyle(Theme.muted.color))
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(Theme.text.color)
                .focused($fieldFocused)
                .accessibilityLabel("Search")
                .onKeyPress(.upArrow) { moveSelection(by: -1) }
                .onKeyPress(.downArrow) { moveSelection(by: 1) }
                .onKeyPress(.return) { openSelected() }
                .onSubmit { _ = openSelected() }

            // The esc key cap doubles as the mouse way out.
            Button { dismiss() } label: {
                KeyCap("esc")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close search")
            .help("Close (esc)")
        }
        .padding(.horizontal, 18)
    }

    // MARK: Filter chips

    private var filterRow: some View {
        let counts = SearchHit.counts(hits)
        return HStack(spacing: 8) {
            filterChip(label: "All", count: hits.count, isOn: filter == nil) { filter = nil }
            ForEach(SearchKind.allCases) { kind in
                filterChip(label: kind.filterLabel, count: counts[kind, default: 0], isOn: filter == kind) { filter = kind }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func filterChip(label: String, count: Int, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                if hasQuery {
                    Text("\(count)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                }
            }
        }
        .buttonStyle(.themeFilterChip(isOn: isOn))
        .accessibilityLabel(hasQuery ? "\(label), \(count) \(count == 1 ? "result" : "results")" : label)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsArea: some View {
        if !hasQuery {
            message("Search names, transcripts, notes and comments.")
        } else if visibleHits.isEmpty {
            message("No results for \u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleHits) { hit in
                            SearchResultRow(hit: hit, query: query, isSelected: hit.id == selectedID) {
                                selectedID = hit.id
                                open(hit)
                            }
                            .id(hit.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(key: ListHeightKey.self, value: geometry.size.height)
                        }
                    )
                }
                .frame(height: min(max(listContentHeight, Self.listMinHeight), Self.listMaxHeight))
                .onPreferenceChange(ListHeightKey.self) { listContentHeight = $0 }
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.muted.color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .frame(height: Self.listMinHeight)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(footerSummary)
            Spacer(minLength: 12)
            if !visibleHits.isEmpty {
                HStack(spacing: 6) {
                    KeyCap("\u{2191}")
                    KeyCap("\u{2193}")
                    Text("move")
                    KeyCap("return").padding(.leading, 8)
                    Text("open")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Up and down arrow keys move, return opens")
            }
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.muted.color)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Theme.sidebar.color)
    }

    private var footerSummary: String {
        guard hasQuery else { return "Searched on this Mac." }
        let shown = visibleHits
        let patients = SearchHit.patientCount(shown)
        let results = shown.count == 1 ? "1 result" : "\(shown.count) results"
        let people = patients == 1 ? "1 patient" : "\(patients) patients"
        return "\(results) across \(people). Searched on this Mac."
    }

    // MARK: Behaviour

    /// Runs the search once typing has paused. `.task(id:)` cancels the previous
    /// run when the query changes, so only the last keystroke searches.
    @MainActor
    private func runSearch() async {
        guard hasQuery, let store = appModel.store else {
            hits = []
            selectedID = nil
            return
        }
        try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
        guard !Task.isCancelled else { return }
        hits = store.searchHits(query: query)
        selectedID = visibleHits.first?.id
    }

    /// Clamps at the first and last result.
    private func moveSelection(by delta: Int) -> KeyPress.Result {
        let list = visibleHits
        guard !list.isEmpty else { return .ignored }
        let current = list.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : list.count)
        let next = min(max(current + delta, 0), list.count - 1)
        selectedID = list[next].id
        return .handled
    }

    private func openSelected() -> KeyPress.Result {
        guard let hit = visibleHits.first(where: { $0.id == selectedID }) else { return .ignored }
        open(hit)
        return .handled
    }

    private func open(_ hit: SearchHit) {
        onOpen(hit.patient, hit.session)
        dismiss()
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One result: kind badge, "<Patient>, <date>" title and a one-line snippet with
/// the query marked.
private struct SearchResultRow: View {
    let hit: SearchHit
    let query: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Chip(hit.kind.badge)
                    .frame(width: 78)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text.color)
                        .lineLimit(1)
                    Text(Self.highlighted(hit.snippet, query: query))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.accentTint.color : (isHovered ? Theme.hover.color : .clear), in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(hit.kind.badge), \(hit.title). \(hit.snippet)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The snippet with each match on the highlight fill.
    private static func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString()
        for segment in SearchHighlighter.segments(in: text, query: query) {
            var piece = AttributedString(segment.text)
            if segment.isMatch {
                piece.backgroundColor = Theme.highlight.color
                piece.foregroundColor = Theme.highlightInk.color
            }
            result.append(piece)
        }
        return result
    }
}
