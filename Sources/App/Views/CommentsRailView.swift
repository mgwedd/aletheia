import SwiftUI

/// The Google-Docs-style comments margin that sits to the right of the
/// transcript. Active comments are shown as cards ordered by where their
/// passage falls in the session; resolved comments collapse into a disclosure
/// at the bottom so they're kept but out of the way.
///
/// The rail is the "text ← → cards" half of the two-way focus: tapping a card
/// sets `focusedCommentID`, which the transcript view watches to scroll-and-
/// flash the passage; clicking a highlighted passage sets the same binding,
/// which scrolls the matching card into view here.
struct CommentsRailView: View {
    let comments: [SessionComment]
    @Binding var focusedCommentID: String?
    var onResolve: (SessionComment, Bool) -> Void
    var onDelete: (SessionComment) -> Void

    /// Active comments, ordered by their position in the session (anchored
    /// first, in time order; un-anchored after, in creation order) so the rail
    /// reads top-to-bottom alongside the transcript.
    private var active: [SessionComment] {
        comments.filter { !$0.resolved }.sorted(by: Self.byTranscriptPosition)
    }

    private var resolved: [SessionComment] {
        comments.filter(\.resolved).sorted { $0.updatedAt > $1.updatedAt }
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
                Label("Comments", systemImage: "bubble.left")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !active.isEmpty {
                    Text("\(active.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            if comments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Select a passage in the transcript and click “Comment on Selection” to add one here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(active) { comment in
                                card(for: comment)
                            }
                            if !resolved.isEmpty {
                                resolvedSection
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: focusedCommentID) { _, id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .frame(minWidth: 240, idealWidth: 300, maxWidth: 360)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder
    private func card(for comment: SessionComment) -> some View {
        let isFocused = focusedCommentID == comment.id
        VStack(alignment: .leading, spacing: 6) {
            if let anchor = comment.anchorSeconds {
                Label(TranscriptTimeline.format(Int(anchor)), systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !comment.quotedText.isEmpty {
                Text("“\(comment.quotedText)”")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Text(comment.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Spacer()
                Button {
                    onResolve(comment, !comment.resolved)
                } label: {
                    Label(comment.resolved ? "Reopen" : "Resolve",
                          systemImage: comment.resolved ? "arrow.uturn.backward.circle" : "checkmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(comment.resolved ? "Reopen this comment" : "Mark this comment resolved")
                Button(role: .destructive) {
                    onDelete(comment)
                } label: {
                    Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Delete this comment")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? Color.yellow.opacity(0.22) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? Color.yellow.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { focusedCommentID = comment.id }
        .id(comment.id)
    }

    private var resolvedSection: some View {
        DisclosureGroup {
            ForEach(resolved) { comment in
                card(for: comment)
                    .opacity(0.7)
            }
        } label: {
            Text("Resolved (\(resolved.count))")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}
