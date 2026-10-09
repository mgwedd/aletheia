import SwiftUI

/// The Google-Docs-style comments margin that sits to the right of the
/// transcript. Active comments are shown as cards ordered by where their
/// passage falls in the session; resolved comments collapse into a disclosure
/// at the bottom so they're kept but out of the way.
///
/// The rail is the "text ← → cards" half of the two-way focus: tapping a card
/// asks the owner to focus it (`onFocus`), which sets `focusedCommentID` and
/// bumps `focusToken` so the transcript view scroll-and-flashes the passage —
/// every time, even for the already-focused card. Clicking a highlighted
/// passage does the same from the other side, which scrolls the matching card
/// into view here.
struct CommentsRailView: View {
    let comments: [SessionComment]
    @Binding var focusedCommentID: String?
    /// Comments whose quoted passage couldn't be placed in the transcript (it
    /// was edited away, or a legacy comment quoted text that repeats). They
    /// still show here, just with a note, and clicking one doesn't scroll.
    var unplacedIDs: Set<String> = []
    /// Bumped by the owner on every focus request, so the rail re-scrolls to the
    /// focused card even when the same card is focused again.
    var focusToken: Int = 0
    /// A card was clicked. The owner sets `focusedCommentID` and bumps
    /// `focusToken`, so this works as a repeatable event rather than a state.
    var onFocus: (String) -> Void = { _ in }
    var onResolve: (SessionComment, Bool) -> Void
    var onDelete: (SessionComment) -> Void
    /// The comment's new body, after Save in the card's editor.
    var onEdit: (SessionComment, String) -> Void = { _, _ in }

    /// The card being edited, and its text so far. One at a time; nothing is
    /// written until Save.
    @State private var editingID: String?
    @State private var editDraft = ""

    /// Active comments, ordered by their position in the session (anchored
    /// first, in time order; un-anchored after, in creation order) so the rail
    /// reads top-to-bottom alongside the transcript.
    private var active: [SessionComment] {
        comments.filter { !$0.resolved }.sorted(by: Self.byTranscriptPosition)
    }

    private var resolved: [SessionComment] {
        comments.filter(\.resolved).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Whether an edited comment can be saved: not blank, and different from what
    /// is stored (ignoring surrounding whitespace).
    static func canSaveEdit(draft: String, original: String) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func byTranscriptPosition(_ a: SessionComment, _ b: SessionComment) -> Bool {
        switch (a.anchorSeconds, b.anchorSeconds) {
        case let (x?, y?): return x != y ? x < y : a.createdAt < b.createdAt
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.createdAt < b.createdAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Comments").eyebrowStyle()
                Spacer()
                if !active.isEmpty {
                    Chip("\(active.count)")
                        .accessibilityLabel("\(active.count) open")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)

            if comments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.title2)
                        .foregroundStyle(Theme.muted.color)
                    Text("Select a passage in the transcript and click “Comment on Selection” to add one here.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(active) { comment in
                                card(for: comment)
                            }
                            if !resolved.isEmpty {
                                resolvedSection
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 16)
                    }
                    .onChange(of: focusToken) { _, _ in
                        guard let id = focusedCommentID else { return }
                        withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .frame(minWidth: 240, idealWidth: 296, maxWidth: 340)
        .background(Theme.window.color)
    }

    @ViewBuilder
    private func card(for comment: SessionComment) -> some View {
        let isFocused = focusedCommentID == comment.id
        VStack(alignment: .leading, spacing: 8) {
            if let anchor = comment.anchorSeconds {
                Chip(TranscriptTimeline.format(Int(anchor)))
                    .accessibilityLabel("At \(TranscriptTimeline.format(Int(anchor)))")
            }
            if !comment.quotedText.isEmpty {
                Text("“\(comment.quotedText)”")
                    .font(Theme.Typography.caption)
                    .italic()
                    .foregroundStyle(Theme.muted.color)
                    .lineLimit(3)
                if unplacedIDs.contains(comment.id) {
                    Label("Original passage not found", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted.color)
                }
            }
            if editingID == comment.id {
                editor(for: comment)
            } else {
                Text(comment.body)
                    .font(Theme.Typography.body)
                    .lineSpacing(2)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 2) {
                Spacer()
                if editingID != comment.id {
                    Button {
                        editDraft = comment.body
                        editingID = comment.id
                        onFocus(comment.id)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .help("Edit this comment")
                }
                Button {
                    onResolve(comment, !comment.resolved)
                } label: {
                    Label(comment.resolved ? "Reopen" : "Resolve",
                          systemImage: comment.resolved ? "arrow.uturn.backward.circle" : "checkmark.circle")
                }
                .help(comment.resolved ? "Reopen this comment" : "Mark this comment resolved")
                Button(role: .destructive) {
                    onDelete(comment)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete this comment")
            }
            .buttonStyle(.themeIcon)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(isEmphasized: isFocused)
        .contentShape(Rectangle())
        .onTapGesture { onFocus(comment.id) }
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .id(comment.id)
    }

    private func editor(for comment: SessionComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorField(text: $editDraft, placeholder: "Comment", minHeight: 70)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { editingID = nil }
                    .buttonStyle(.themed)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onEdit(comment, editDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                    editingID = nil
                }
                .buttonStyle(.themePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!Self.canSaveEdit(draft: editDraft, original: comment.body))
            }
            .controlSize(.small)
        }
    }

    private var resolvedSection: some View {
        DisclosureGroup {
            ForEach(resolved) { comment in
                card(for: comment)
                    .opacity(0.7)
            }
        } label: {
            Text("Resolved (\(resolved.count))")
                .font(Theme.Typography.caption.weight(.medium))
                .foregroundStyle(Theme.muted.color)
        }
        .padding(.top, 4)
    }
}
