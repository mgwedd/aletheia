import SwiftUI
import AppKit

/// Sizes and key handling of the chat composer, apart from the view so they
/// can be tested.
enum ChatComposerLayout {
    /// The field grows with its text between these heights, then scrolls.
    static let minFieldHeight: CGFloat = 40
    static let maxFieldHeight: CGFloat = 120
    /// Width kept clear inside the box, at its trailing edge, for the Stop or
    /// mic icon (a 28pt button, 6pt in from the edge, and a little air).
    static let accessoryWidth: CGFloat = 40

    /// What sits at the trailing edge of the composer.
    enum TrailingControl: Equatable {
        /// The Send button beside the box.
        case send
        /// The round Stop button inside the box, while an answer is being made.
        case stop
    }

    static func trailingControl(isSending: Bool, canStop: Bool) -> TrailingControl {
        isSending && canStop ? .stop : .send
    }

    /// Esc stops a running answer; idle, it is left for whatever else wants it
    /// (closing a sheet, clearing search).
    static func escapeStops(isSending: Bool, canStop: Bool) -> Bool {
        isSending && canStop
    }

    /// A question is one paragraph: any run of line breaks (a pasted
    /// paragraph, say) becomes a single space when it is sent.
    static func collapsingLineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s*[\\r\\n]+\\s*", with: " ", options: .regularExpression)
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
    /// Caveats about the last answer, shown above the composer in muted type.
    var notices: [String] = []
    /// What is under way before the model starts (e.g. searching), shown as
    /// the status line in place of the model's progress.
    var busyNotice: String?
    /// When that work began, for the line's elapsed counter.
    var busySince: Date? = nil
    /// Where that work stands overall, for a bar above `busyNotice`.
    var busySteps: AIRunSteps? = nil
    /// Compacts the conversation, with an optional focus: the Compact button
    /// and the `/compact [focus]` command. Nil hides both.
    var onCompact: ((String) -> Void)? = nil
    /// Live state of the running answer; drives the progress line under the conversation.
    var progress = AIRunProgress()
    /// Optional Fast / Normal / Focus selector shown above the field (#286 Step 5b).
    var effort: Binding<AnswerEffort>? = nil
    /// Which chat the selector applies to, for its description.
    var effortFeature: EffortFeature = .sessionChat
    /// True while a session is being recorded: the recorder owns the
    /// microphone, so the dictation mic is hidden.
    var isSessionRecording = false
    /// The dictation engine; nil uses on-device Apple Speech. Tests pass a fake.
    var voiceInput: VoiceInput? = nil

    @State private var draft: String = ""
    @State private var inputFocused = false
    /// Bumped on send so dictation stops writing into the cleared draft.
    @State private var voiceResetToken = 0
    /// Whether the mic is drawn, reported by the mic itself.
    @State private var micShown = false

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        VStack(spacing: 0) {
            conversation
            Text("AI generated responses can be inaccurate. Double-check responses.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .accessibilityIdentifier("chat.disclaimer")
            if !notices.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
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
        .selectablePatientText()
        // Esc from anywhere else in the pane; idle, it is left alone.
        .onExitCommand(perform: ChatComposerLayout.escapeStops(isSending: isSending, canStop: onStop != nil) ? { _ = escapeStops() } : nil)
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
                    // Zero-height end marker: scrolling to it lands on the true
                    // bottom, under the stack's spacing, not 20pt short of it.
                    Color.clear.frame(height: 0).id(Self.bottomID)
                }
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 0, trailing: 20))
                .background(ChatBottomFollower(followToken: messages.count))
            }
            // A thread opens at its latest message, not its first. The anchor
            // covers the first layout and later growth; the explicit jumps
            // below cover a different thread arriving in this same view.
            .defaultScrollAnchor(.bottom)
            .onAppear { jumpToLatest(proxy) }
            .onChange(of: messages.first?.id) { _, _ in
                jumpToLatest(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.muted.color)
                .accessibilityHidden(true)
            Text(ChatWords.emptyTitle(about: title))
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
        } else if let busyNotice {
            VStack(alignment: .leading, spacing: 6) {
                if let busySteps {
                    ThemeProgressBar(value: busySteps.fraction)
                        .frame(maxWidth: 240)
                }
                if let busySince {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        AIStatusLineView(text: AIProgressFormat.busyLine(busyNotice, since: busySince, now: context.date))
                    }
                } else {
                    AIStatusLineView(text: busyNotice)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // A run of several calls (a long patient history) shows where it is overall.
                if let steps = progress.steps {
                    ThemeProgressBar(value: steps.fraction)
                        .frame(maxWidth: 240)
                }
                AIProgressView(progress: progress)
            }
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
            if effort != nil || showsCompact {
                effortRow(effort)
            }
            HStack(alignment: .bottom, spacing: 10) {
                inputField
                if ChatComposerLayout.trailingControl(isSending: isSending, canStop: onStop != nil) == .send {
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

    /// The shared themed text area: it grows with the text up to
    /// `maxFieldHeight`, then scrolls. Return, Enter, Shift-Return and
    /// Option-Return all send (never a line break); Tab moves on to the next control.
    private var inputField: some View {
        ThemeTextArea(
            text: $draft,
            placeholder: "Ask about \(title)…",
            height: .grows(min: ChatComposerLayout.minFieldHeight, max: ChatComposerLayout.maxFieldHeight),
            accessibilityLabel: "Ask about \(title)",
            onSubmit: send,
            onEscape: escapeStops,
            modifiedReturnSubmits: true,
            tabMovesFocus: true,
            trailingInset: trailingAccessoryShown ? ChatComposerLayout.accessoryWidth : 0,
            isFocused: $inputFocused
        )
        .disabled(isSending)
        .overlay(alignment: .trailing) {
            HStack(spacing: 2) {
                if ChatComposerLayout.trailingControl(isSending: isSending, canStop: onStop != nil) == .stop, let onStop {
                    StopButton(action: onStop)
                }
                VoiceMicControl(
                    draft: $draft,
                    isSending: isSending,
                    isSessionRecording: isSessionRecording,
                    resetToken: voiceResetToken,
                    input: voiceInput,
                    onShownChange: { micShown = $0 }
                )
            }
            .padding(.trailing, 6)
        }
    }

    /// Stop or the mic is drawn over the box's trailing edge.
    private var trailingAccessoryShown: Bool {
        micShown || ChatComposerLayout.trailingControl(isSending: isSending, canStop: onStop != nil) == .stop
    }

    /// Esc while an answer is being made stops it; true when it did.
    private func escapeStops() -> Bool {
        guard ChatComposerLayout.escapeStops(isSending: isSending, canStop: onStop != nil), let onStop else { return false }
        onStop()
        return true
    }

    private var showsCompact: Bool {
        onCompact != nil && ChatMemory.hasHistory(messages)
    }

    /// The bar above the field: the Fast / Normal / Focus selector at the
    /// leading edge, Compact at the trailing edge.
    private func effortRow(_ effort: Binding<AnswerEffort>?) -> some View {
        HStack(spacing: 10) {
            if let effort {
                Text(AnswerEffort.label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                ThemeSegmentedControl(
                    options: AnswerEffort.allCases.map { ThemeTab(value: $0, title: $0.displayName) },
                    selection: effort
                )
                .frame(width: 240)
                .disabled(isSending)
                .help(effort.wrappedValue.blurb(for: effortFeature))
                .accessibilityLabel(AnswerEffort.label)
            }
            Spacer(minLength: 16)
            if showsCompact {
                Button("Compact") { onCompact?("") }
                    .buttonStyle(.themed)
                    .controlSize(.small)
                    .disabled(isSending)
                    .hoverTip(HelpTips.compact, arrowEdge: .top)
            }
        }
    }

    /// Unanimated jump to the latest message, repeated once the lazy stack has
    /// measured what it just loaded (the first attempt can land short).
    private static let bottomID = "chat-bottom"

    private func jumpToLatest(_ proxy: ScrollViewProxy) {
        guard !messages.isEmpty else { return }
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
        DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }

    private func send() {
        let text = ChatComposerLayout.collapsingLineBreaks(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return }
        voiceResetToken += 1
        draft = ""
        if let onCompact, let focus = ChatMemory.compactCommand(text) {
            onCompact(focus)
        } else {
            onSend(text)
        }
    }
}

/// The in-box Stop control: a stop square in a circle, no fill or border.
struct StopButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(hovering ? Theme.text.color : Theme.muted.color, lineWidth: 1.5)
                    .frame(width: 20, height: 20)
                Image(systemName: "stop.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovering ? Theme.text.color : Theme.muted.color)
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Stop (Esc)")
        .accessibilityLabel("Stop")
        .accessibilityHint("Stops generating the answer. Escape does the same.")
    }
}

// MARK: - Messages

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .summary {
            // A compaction: what later answers remember of everything above.
            VStack(alignment: .leading, spacing: 8) {
                Chip(ChatWords.compactedChip)
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
                    .selectablePatientText()
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

/// Keeps the conversation on its latest line while an answer streams in, the
/// way chat apps do: while the reader is at the bottom, every growth of the
/// content (a new chunk, a re-measured row, the progress line going away)
/// keeps them there. Any scroll up by the reader stops it at once, and nothing
/// moves while they are mid-gesture: the reader wins. Scrolling back to the
/// bottom, or sending a message (`followToken` changes), resumes it. Done on the
/// AppKit scroll view directly, unanimated, so no SwiftUI scroll fights it.
private struct ChatBottomFollower: NSViewRepresentable {
    let followToken: Int

    func makeNSView(context: Context) -> ChatBottomFollowerView { ChatBottomFollowerView() }

    func updateNSView(_ view: ChatBottomFollowerView, context: Context) {
        if view.followToken != followToken {
            view.followToken = followToken
            view.follow()
        }
    }
}

final class ChatBottomFollowerView: NSView {
    var followToken = 0
    /// Within this of the bottom counts as at the bottom.
    static let slack: CGFloat = 40
    private(set) var isFollowing = true
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    /// Set while this view moves the scroll itself, so it isn't read as the reader scrolling.
    private var pinning = false
    /// A trackpad or scroll-bar drag in progress.
    private var liveScrolling = false
    private var lastDistance: CGFloat = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard window != nil, let scroll = enclosingScrollView, let document = scroll.documentView else { return }
        scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        document.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.readerScrolled() } })
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification, object: document, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.contentChanged() } })
        observers.append(center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.liveScrolling = true } })
        observers.append(center.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.liveScrolling = false
                self?.readerScrolled()
            }
        })
        follow()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func follow() {
        isFollowing = true
        pin()
    }

    private var distanceFromBottom: CGFloat {
        guard let scroll = scrollView, let document = scroll.documentView else { return 0 }
        let visible = scroll.contentView.documentVisibleRect
        return document.isFlipped ? document.frame.height - visible.maxY : visible.minY
    }

    private func readerScrolled() {
        guard !pinning else { return }
        let distance = distanceFromBottom
        // Moving up at all means the reader wants the history; otherwise follow
        // again once they are back at the bottom.
        isFollowing = distance <= lastDistance + 0.5 && distance <= Self.slack
        lastDistance = distance
    }

    private func contentChanged() {
        if isFollowing && !liveScrolling { pin() } else { lastDistance = distanceFromBottom }
    }

    private func pin() {
        guard let scroll = scrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        let y = document.isFlipped ? maxY : 0
        guard abs(clip.bounds.origin.y - y) > 0.5 else { return }
        pinning = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
        pinning = false
        lastDistance = distanceFromBottom
    }
}
