import SwiftUI
import TipKit
import os

private let log = Logger(subsystem: "com.aletheia", category: "Tips")

// MARK: - Tips

/// A "how this works" line that used to sit in the layout. It now shows once,
/// as a popover just below the pointer after it rests on its control
/// (`hoverTip(_:)`), closes when the pointer leaves, and stays away after it
/// has been read. The same text stays on the control as
/// its VoiceOver hint, and as its tooltip once the tip has been read.
///
/// Read state is keyed by `id` alone, so a tip whose text follows a selection
/// (the note format) is read once, not once per option.
struct HelpTip: Tip, Equatable {
    let id: String
    let heading: String
    let text: String

    var title: Text { Text(heading) }
    var message: Text? { Text(text) }
}

/// Every tip the app shows. The ids are stored on this Mac with each tip's
/// read state, so renaming one shows it again: treat them as fixed.
enum HelpTips {
    static let myNotes = HelpTip(
        id: "notes.mine",
        heading: "Psychotherapy note",
        text: NoteKind.psychotherapyHelp
    )

    static let compact = HelpTip(
        id: "chat.compact",
        heading: "Compact this chat",
        text: "Compressing the conversation improves the AI's understanding and performance in longer conversations."
    )

    // Settings. Safety and privacy lines (app lock, encryption, backups,
    // what reaches the assistant) stay in the layout; these are the asides.

    static let autoTranscribe = HelpTip(
        id: "settings.autoTranscribe",
        heading: "Transcribe automatically",
        text: "Starts transcription as soon as you stop recording, so the transcript is ready when you come back. It keeps running while Aletheia is locked, and you get a notification when it's done."
    )

    static let aiInstructions = HelpTip(
        id: "settings.aiInstructions",
        heading: "AI instructions",
        text: "The standing instructions sent with every AI request — the assistant's voice and rules. Editing this changes how summaries and chat behave."
    )

    static let defaultNoteFormat = HelpTip(
        id: "settings.defaultNoteFormat",
        heading: "Default progress note format",
        text: "The format new session notes start in. You can still switch formats for any single session on its Note tab."
    )

    static let includeComments = HelpTip(
        id: "settings.includeComments",
        heading: "Include comments in drafts",
        text: "Margin comments on the transcript are folded into generated progress notes and summaries."
    )

    static let summariesOnBattery = HelpTip(
        id: "settings.summariesOnBattery",
        heading: "Prepare summaries on battery",
        text: "Summaries use the local model for a few minutes per hour of session, which drains battery. Low Power Mode still pauses them."
    )
}

/// TipKit's store: on this Mac only. Tips hold only which explainer has been
/// read — never patient data — but they still stay local: the store lives in
/// the app's own container (not the user-chosen data folder, which may be in
/// iCloud Drive), and CloudKit sync is turned off where macOS offers it
/// (macOS 15+). macOS 14 has no TipKit sync, and the app has no iCloud
/// entitlement either way (`scripts/check-entitlements.sh`).
enum HelpTipsStore {
    static let datastoreLocation: Tips.ConfigurationOption.DatastoreLocation = .applicationDefault
    /// Hover is the trigger, so TipKit shouldn't also space tips out.
    static let displayFrequency: Tips.ConfigurationOption.DisplayFrequency = .immediate

    static var options: [Tips.ConfigurationOption] {
        var options: [Tips.ConfigurationOption] = [
            .datastoreLocation(datastoreLocation),
            .displayFrequency(displayFrequency),
        ]
        if #available(macOS 15.0, *) {
            options.append(.cloudKitContainer(nil))
        }
        return options
    }

    /// Once, at launch. A failure only means no tips: the text is still each
    /// control's tooltip and VoiceOver hint.
    static func configure() {
        do {
            try Tips.configure(options)
        } catch {
            log.error("TipKit couldn't be configured: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Hover delay

/// When a resting pointer has earned a tip: `delay` after it entered, as long
/// as it hasn't left (or left and come back) since. Pure, so the timing is
/// tested without a run loop; the view sleeps until `Deadline.instant` and asks.
struct HoverIntent {
    static let defaultDelay: Duration = .seconds(2)

    struct Deadline: Equatable {
        let generation: Int
        let instant: ContinuousClock.Instant
    }

    let delay: Duration
    private var generation = 0
    private var armed: Deadline?
    /// The tip is on screen: from its deadline until the pointer leaves.
    private(set) var isShowing = false

    init(delay: Duration = HoverIntent.defaultDelay) {
        self.delay = delay
    }

    /// The pointer entered; any earlier deadline is void.
    mutating func enter(at now: ContinuousClock.Instant) -> Deadline {
        generation += 1
        let deadline = Deadline(generation: generation, instant: now + delay)
        armed = deadline
        return deadline
    }

    /// The pointer left: a showing tip closes, and nothing fires until it
    /// enters again.
    mutating func exit() {
        generation += 1
        armed = nil
        isShowing = false
    }

    func isDue(_ deadline: Deadline, at now: ContinuousClock.Instant) -> Bool {
        armed == deadline && now >= deadline.instant
    }

    /// The view's timer woke at `now`: the tip shows if `deadline` is due.
    mutating func wake(_ deadline: Deadline, at now: ContinuousClock.Instant) -> Bool {
        if isDue(deadline, at: now) { isShowing = true }
        return isShowing
    }
}

/// Where a tip opens: just below the pointer, where a tooltip would, on every
/// control. Anchored to the view's bounds instead, a tall control put the
/// tip at its top or bottom center, far from the pointer.
enum HoverTipPlacement {
    /// Clears the arrow cursor drawn below the pointer's hotspot.
    static let gap: CGFloat = 18

    /// The point the popover's arrow touches, in the control's coordinates.
    static func anchor(below pointer: CGPoint) -> CGRect {
        CGRect(x: pointer.x, y: pointer.y + gap, width: 1, height: 1)
    }
}

// MARK: - Modifier

extension View {
    /// Shows `tip` in a popover below the pointer once it has rested on this
    /// view for two seconds, until it has been read. The popover closes when
    /// the pointer leaves; once shown it counts as read and doesn't come back.
    func hoverTip(_ tip: HelpTip) -> some View {
        modifier(HoverTipModifier(tip: tip))
    }

    /// No tip when `tip` is nil.
    @ViewBuilder
    func hoverTip(_ tip: HelpTip?) -> some View {
        if let tip { modifier(HoverTipModifier(tip: tip)) } else { self }
    }
}

private struct HoverTipModifier: ViewModifier {
    let tip: HelpTip

    @State private var intent = HoverIntent()
    @State private var pending: Task<Void, Never>?
    @State private var isPresented = false
    @State private var isInside = false
    @State private var pointer = CGPoint.zero
    /// Fixed when the tip opens, so it doesn't chase the pointer.
    @State private var anchor = CGRect.zero
    /// TipKit's view of the tip: false once read (or if TipKit isn't set up).
    @State private var isUnread = false

    func body(content: Content) -> some View {
        content
            // Until it's read the tip is the hover help; a tooltip a second
            // earlier would only cover it.
            .help(isUnread ? "" : tip.text)
            .accessibilityHint(Text(tip.text))
            .onContinuousHover(coordinateSpace: .local, perform: hoverChanged)
            .popover(isPresented: $isPresented, attachmentAnchor: .rect(.rect(anchor)), arrowEdge: .bottom) {
                TipView(tip)
                    .tipViewStyle(ThemedTipViewStyle())
                    .tipBackground(Theme.raised.color)
            }
            .onChange(of: isPresented) { _, shown in
                if !shown {
                    tip.invalidate(reason: .tipClosed)
                    intent.exit()
                }
            }
            .task(id: tip.id) {
                for await shouldDisplay in tip.shouldDisplayUpdates {
                    isUnread = shouldDisplay
                }
            }
            .onDisappear {
                pending?.cancel()
                intent.exit()
                isPresented = false
            }
    }

    private func hoverChanged(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            pointer = location
            guard !isInside else { return }
            isInside = true
            arm()
        case .ended:
            isInside = false
            pending?.cancel()
            intent.exit()
            isPresented = false
        }
    }

    private func arm() {
        pending?.cancel()
        guard isUnread else { return }
        let deadline = intent.enter(at: .now)
        pending = Task { @MainActor in
            try? await Task.sleep(until: deadline.instant, clock: .continuous)
            if !Task.isCancelled, intent.wake(deadline, at: .now) {
                anchor = HoverTipPlacement.anchor(below: pointer)
                isPresented = true
            }
        }
    }
}

/// The tip in the app's own colors. No close button: like a tooltip, it
/// closes when the pointer leaves its control (or on Escape).
private struct ThemedTipViewStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            configuration.title?
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.text.color)
            configuration.message?
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(Theme.raised.color)
    }
}
