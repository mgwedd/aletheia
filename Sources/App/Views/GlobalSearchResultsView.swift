import AppKit
import SwiftUI

/// Global search results, shown over the detail pane while the search field
/// has a query. One list, grouped: Patients, Sessions, Psychotherapy notes, Progress
/// notes, Comments, Transcripts, each best first with a "Show more" row. A
/// line at the top says when the index is still being built, so partial
/// results never pass for complete ones.
///
///   ┌──────────────────────────────────────────────────────────────┐
///   │ ⓘ Indexing 12 sessions; results may be incomplete.           │
///   │ PATIENTS  1                                                   │
///   │   Jane Doe                         4 sessions                 │
///   │ TRANSCRIPTS  30                                               │
///   │   Jane Doe, Oct 8, 2026            [00:57] … insomnia …       │
///   │   Show 25 more                                                │
///   │ [↑][↓] move  [↩] open  [esc] clear              30 results     │
///   └──────────────────────────────────────────────────────────────┘
struct GlobalSearchResultsView: View {
    @ObservedObject var model: GlobalSearchModel
    let onOpen: (SearchHit) -> Void
    @State private var lastAnnouncement = ""

    var body: some View {
        VStack(spacing: 0) {
            if let status = model.results.coverage.statusText {
                statusLine(status)
            }
            if model.results.sections.isEmpty {
                emptyMessage
            } else {
                resultList
            }
            footer
                .themeDivider(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window.color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search results")
        .onChange(of: model.results) { _, results in announce(results) }
    }

    // MARK: Parts

    private func statusLine(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.text.color)
            Spacer(minLength: 0)
        }
        .themeBanner(.info)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
    }

    private var emptyMessage: some View {
        Text(GlobalSearchRow.emptyMessage(query: model.query, results: model.results))
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.muted.color)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.results.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: model.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: GlobalSearchSection) -> some View {
        SectionHeader(kind: section.kind, total: section.total)
        ForEach(section.hits) { hit in
            ResultRow(hit: hit, query: model.query, isSelected: model.selectedID == hit.id) {
                model.select(hit.id)
                onOpen(hit)
            }
            .id(hit.id)
        }
        if let more = GlobalSearchRow.more(for: section, limits: model.limits) {
            MoreRow(
                title: GlobalSearchRow.moreTitle(hidden: section.hiddenCount), kind: section.kind,
                isSelected: model.selectedID == more.id
            ) {
                _ = model.activate(more.id)
            }
            .id(more.id)
        }
        if let note = GlobalSearchRow.cappedNote(for: section, limits: model.limits) {
            Text(note)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if !model.rows.isEmpty {
                ShortcutHint(KeyboardShortcut(.upArrow, modifiers: []))
                ShortcutHint(KeyboardShortcut(.downArrow, modifiers: []))
                Text("move")
                ShortcutHint(.defaultAction).padding(.leading, 8)
                Text("open")
            }
            ShortcutHint(.cancelAction).padding(.leading, model.rows.isEmpty ? 0 : 8)
            Text("clear")
            Spacer(minLength: 12)
            Text(summary)
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.muted.color)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Theme.sidebar.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            model.rows.isEmpty
                ? "Escape clears the search. \(summary)"
                : "Up and down arrow keys move, Return opens, Escape clears the search. \(summary)")
    }

    private var summary: String {
        let total = model.results.total
        guard total > 0 else { return "" }
        return total == 1 ? "1 result" : "\(total) results"
    }

    /// Tells VoiceOver how many results there are (and whether they may be
    /// incomplete) when that changes, not on every re-run.
    private func announce(_ results: GlobalSearchResults) {
        guard model.hasQuery else { return }
        let text = GlobalSearchAnnouncement.text(for: results)
        guard text != lastAnnouncement else { return }
        lastAnnouncement = text
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }
}

/// A group's heading: its name and how many matched.
private struct SectionHeader: View {
    let kind: SearchKind
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(kind.filterLabel)
                .eyebrowStyle()
            Chip("\(total)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.filterLabel), \(total) \(total == 1 ? "result" : "results")")
        .accessibilityAddTraits(.isHeader)
    }
}

/// One result: "<Patient>, <date>" (plus the note format or comment time) and
/// a one-line snippet with the matching words marked.
private struct ResultRow: View {
    let hit: SearchHit
    let query: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                Text(Self.highlighted(hit.snippet, query: query))
                    .font(.system(size: 13))
                    // On the selected row's tint only the full-strength ink meets the contrast contract.
                    .foregroundStyle(isSelected ? Theme.text.color : Theme.muted.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.accentTint.color : (isHovered ? Theme.hover.color : Theme.window.color), in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(hit.kind.badge), \(hit.title). \(hit.snippet)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The snippet with each matching word on the highlight fill.
    private static func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString()
        for segment in GlobalSearchHighlight.segments(in: text, query: query) {
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

/// "Show 25 more", selectable like a result.
private struct MoreRow: View {
    let title: String
    let kind: SearchKind
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.text.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? Theme.accentTint.color : (isHovered ? Theme.hover.color : Theme.window.color), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(title) \(kind.filterLabel.lowercased())")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
