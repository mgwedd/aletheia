import SwiftUI
import AppKit

/// Sizes and key handling of the chat composer, apart from the view so they
/// can be tested.
enum ChatComposerLayout {
    /// The field grows with its text between these heights, then scrolls.
    static let minFieldHeight: CGFloat = 40
    static let maxFieldHeight: CGFloat = 120

    enum ReturnKeyAction: Equatable {
        case send
        case newline
    }

    /// Return sends; Shift or Option with Return adds a line.
    static func returnKeyAction(shift: Bool, option: Bool) -> ReturnKeyAction {
        shift || option ? .newline : .send
    }

    enum TabKeyAction: Equatable {
        case nextControl
        case previousControl
    }

    /// A multi-line editor inserts a tab character for Tab; here it moves focus
    /// on, as the single-line field it replaced did.
    static func tabKeyAction(shift: Bool) -> TabKeyAction {
        shift ? .previousControl : .nextControl
    }

    /// The text the invisible sizing copy of the field measures: never empty
    /// (the empty field is still one line tall), and a trailing newline counts
    /// as the line it starts.
    static func sizingText(for draft: String) -> String {
        if draft.isEmpty || draft.hasSuffix("\n") { return draft + " " }
        return draft
    }
}

/// Reusable chat UI shared by the per-session and cross-patient chat
/// features. Deliberately dumb: the caller owns the message list and
/// decides what "send" means (which transcript/context to include).
///
///   scope caption    what the answers are drawn from
///   conversation     questions in trailing bubbles, answers plain on the panel
///   notices          caller-supplied caveats (coverage, unreadable sessions)
///   composer         suggestion pills (empty chat only) · field · Send / Stop
struct ChatPaneView: View {
    let title: String
    @Binding var messages: [ChatMessage]
    var isSending: Bool
    var suggestions: [String] = []
    var onSend: (String) -> Void
    /// When provided, a Stop button appears while `isSending` so the user can
    /// halt a long generation and keep whatever streamed in so far.
    var onStop: (() -> Void)? = nil
    /// Set while the question is waiting behind another generation (see
    /// `InferenceQueue`). Replaces the "Thinking…" spinner with this calm
    /// status and a Cancel button (which calls `onStop`).
    var queuedStatus: String? = nil
    /// One line under the top edge saying what the answers are drawn from.
    /// The default describes the per-session chat; an empty string hides it.
    var scopeNote: String = "Answers come from this session's transcript, your notes and comments."
    /// Caveats about the last answer, shown above the composer in muted type.
    var notices: [String] = []
    /// A caveat shown with a small spinner while work is under way (e.g. searching).
    var busyNotice: String?
    /// Compacts the conversation, with an optional focus: the Compact button
    /// and the `/compact [focus]` command. Nil hides both.
    var onCompact: ((String) -> Void)? = nil
    /// Live state of the running answer, and the model's measured read speed
    /// (for the time estimate); drives the progress line under the conversation.
    var progress = AIRunProgress()
    var speed: ModelSpeed? = nil
    /// Optional Fast / Normal / Focus selector shown above the field (#286 Step 5b).
    var effort: Binding<AnswerEffort>? = nil

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        VStack(spacing: 0) {
            if !scopeNote.isEmpty {
                Text(scopeNote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .themeDivider(.bottom)
            }
            conversation
            if onCompact != nil, ChatMemory.hasHistory(messages) {
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    Button("Compact") { onCompact?("") }
                        .buttonStyle(.themed)
                        .controlSize(.small)
                        .disabled(isSending)
                        .help("Summarize the conversation so far to make room for more. Type /compact followed by a topic to keep that topic in detail.")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            if !notices.isEmpty || busyNotice != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let busyNotice {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini).accessibilityHidden(true)
                            Text(busyNotice)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.muted.color)
                        }
                    }
                    ForEach(notices, id: \.self) { notice in
                        Text(notice)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.muted.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            composer
        }
        .background(Theme.panel.color)
        .textSelection(.enabled)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            BoundedScroll {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if messages.isEmpty {
                        emptyState
                    }
                    ForEach(messages) { message in
                        ChatBubble(message: message).id(message.id)
                    }
                    if isSending {
                        progressIndicator
                            .id("sending-indicator")
                    }
                }
                .padding(20)
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: messages.last?.text) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: isSending) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.muted.color)
                .accessibilityHidden(true)
            Text("Ask a question about \(title)")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.text.color)
            Text("The AI only knows what's in the transcript(s) here.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if let queuedStatus {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .foregroundStyle(Theme.muted.color)
                    .accessibilityHidden(true)
                Text(queuedStatus)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                if let onStop {
                    Button("Cancel", action: onStop)
                        .buttonStyle(.themed)
                        .controlSize(.small)
                }
            }
        } else {
            AIProgressView(progress: progress, speed: speed)
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if messages.isEmpty && !suggestions.isEmpty {
                SuggestionFlowLayout(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { onSend(suggestion) }
                            .buttonStyle(SuggestionPillStyle())
                            .disabled(isSending)
                    }
                }
            }
            if let effort {
                effortRow(effort)
            }
            HStack(alignment: .bottom, spacing: 10) {
                inputField
                if isSending, let onStop {
                    Button(role: .destructive, action: onStop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.themed)
                    .controlSize(.large)
                    .help("Stop generating")
                } else {
                    Button("Send", action: send)
                        .buttonStyle(.themePrimary)
                        .controlSize(.large)
                        .disabled(!canSend)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .themeDivider(.top)
    }

    /// The field is a `TextEditor` so it scrolls (a vertical `TextField` clips
    /// past its line limit). An invisible copy of the text sizes it: it grows
    /// with the text up to `maxFieldHeight`, then the editor scrolls.
    private var inputField: some View {
        Text(ChatComposerLayout.sizingText(for: draft))
            .font(Theme.Typography.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .frame(minHeight: ChatComposerLayout.minFieldHeight, maxHeight: ChatComposerLayout.maxFieldHeight)
            .overlay {
                TextEditor(text: $draft)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .scrollContentBackground(.hidden)
                    .focused($inputFocused)
                    .disabled(isSending)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .onKeyPress(.tab, phases: .down) { press in
                        switch ChatComposerLayout.tabKeyAction(shift: press.modifiers.contains(.shift)) {
                        case .nextControl: NSApp.keyWindow?.selectNextKeyView(nil)
                        case .previousControl: NSApp.keyWindow?.selectPreviousKeyView(nil)
                        }
                        return .handled
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        switch ChatComposerLayout.returnKeyAction(
                            shift: press.modifiers.contains(.shift),
                            option: press.modifiers.contains(.option)
                        ) {
                        case .send:
                            send()
                            return .handled
                        case .newline:
                            return .ignored
                        }
                    }
            }
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Ask about \(title)…")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted.color)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .themeField(isFocused: inputFocused)
    }

    private func effortRow(_ effort: Binding<AnswerEffort>) -> some View {
        HStack(spacing: 10) {
            Text(AnswerEffort.label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
            ThemeSegmentedControl(
                options: AnswerEffort.allCases.map { ThemeTab(value: $0, title: $0.displayName) },
                selection: effort
            )
            .frame(width: 240)
            .disabled(isSending)
            .help(effort.wrappedValue.blurb)
            .accessibilityLabel(AnswerEffort.label)
            Spacer(minLength: 0)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : Animation.easeOut(duration: 0.15)) {
            if isSending {
                proxy.scrollTo("sending-indicator", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        if let onCompact, let focus = ChatMemory.compactCommand(text) {
            onCompact(focus)
        } else {
            onSend(text)
        }
    }
}

// MARK: - Messages

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .summary {
            // A compaction: what later answers remember of everything above.
            VStack(alignment: .leading, spacing: 8) {
                Chip("Conversation compacted")
                MarkdownMessageView(text: message.text)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            }
            .padding(12)
            .frame(maxWidth: 640, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.line.color))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else if message.role == .user {
            // The therapist's own words, shown verbatim in a trailing bubble
            // at most 70% as wide as the pane.
            TrailingBubbleLayout(fraction: 0.7) {
                Text(message.text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.bubble.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            // The assistant answer, rendered as rich Markdown at reading size
            // (like ChatGPT/Claude) so headings, lists, and code read as a
            // document rather than a cramped bubble of raw markup.
            MarkdownMessageView(text: message.text)
                .font(Theme.Typography.reading)
                .lineSpacing(Theme.Typography.readingLineSpacing)
                .foregroundStyle(Theme.text.color)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Lays out one child flush to the trailing edge, proposing it at most
/// `fraction` of the available width, so a short question hugs its text and a
/// long one wraps at 70%.
private struct TrailingBubbleLayout: Layout {
    var fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let limited = proposal.width.map { $0 * fraction }
        let size = child.sizeThatFits(ProposedViewSize(width: limited, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width * fraction, height: nil))
        child.place(
            at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(size)
        )
    }
}

// MARK: - Suggestions

/// A row of views that wraps onto further lines when it runs out of width.
private struct SuggestionFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(maxWidth: bounds.width, subviews: subviews)
        for (index, child) in subviews.enumerated() {
            let frame = result.frames[index]
            child.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let limit: CGFloat? = maxWidth.isFinite ? maxWidth : nil
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for child in subviews {
            let size = child.sizeThatFits(ProposedViewSize(width: limit, height: nil))
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (frames, CGSize(width: usedWidth, height: y + rowHeight))
    }
}

/// A suggested question: 30pt pill, hairline border, raised fill that takes
/// the hover fill under the pointer.
private struct SuggestionPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SuggestionPill(configuration: configuration)
    }
}

private struct SuggestionPill: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let highlighted = isEnabled && (isHovered || configuration.isPressed)
        configuration.label
            .font(Theme.Typography.control)
            .lineLimit(1)
            .foregroundStyle(isEnabled ? Theme.text.color : Theme.muted.color)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(highlighted ? Theme.hover.color : Theme.raised.color, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line.color, lineWidth: 1))
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}
