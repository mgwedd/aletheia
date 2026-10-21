import SwiftUI
import TipKit
import os

private let log = Logger(subsystem: "com.aletheia", category: "Tips")

// MARK: - Tips

/// A "how this works" line that used to sit in the layout. It now shows once,
/// as a popover after the pointer rests on its control (`hoverTip(_:)`), and
/// stays away after it has been read. The same text stays on the control as
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
    static func noteFormat(_ format: ProgressNoteFormat) -> HelpTip {
        HelpTip(id: "notes.format", heading: format.displayName, text: format.blurb)
    }

    static let myNotes = HelpTip(
        id: "notes.mine",
        heading: "My notes",
        text: "Your own notes for this session — jot things down during or after the session. Kept separate from the transcript, and included when you ask about this session."
    )

    static let sessionChatScope = HelpTip(
        id: "chat.session.scope",
        heading: "What answers come from",
        text: "Answers come from this session's transcript, your notes and comments."
    )

    static let patientChatScope = HelpTip(
        id: "chat.patient.scope",
        heading: "What answers come from",
        text: PatientChatView.scopeNote
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

    /// The pointer left: nothing fires until it enters again.
    mutating func exit() {
        generation += 1
        armed = nil
    }

    func isDue(_ deadline: Deadline, at now: ContinuousClock.Instant) -> Bool {
        armed == deadline && now >= deadline.instant
    }
}

// MARK: - Modifier

extension View {
    /// Shows `tip` in a popover once the pointer has rested on this view for
    /// two seconds, until it has been read. Closing or dismissing the popover
    /// counts as read; it doesn't come back.
    func hoverTip(_ tip: HelpTip, arrowEdge: Edge = .bottom) -> some View {
        modifier(HoverTipModifier(tip: tip, arrowEdge: arrowEdge))
    }
}

private struct HoverTipModifier: ViewModifier {
    let tip: HelpTip
    let arrowEdge: Edge

    @State private var intent = HoverIntent()
    @State private var pending: Task<Void, Never>?
    @State private var isPresented = false
    /// TipKit's view of the tip: false once read (or if TipKit isn't set up).
    @State private var isUnread = false

    func body(content: Content) -> some View {
        content
            // Until it's read the tip is the hover help; a tooltip a second
            // earlier would only cover it.
            .help(isUnread ? "" : tip.text)
            .accessibilityHint(Text(tip.text))
            .onHover(perform: hoverChanged)
            .popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
                TipView(tip)
                    .tipViewStyle(ThemedTipViewStyle())
                    .tipBackground(Theme.raised.color)
            }
            .onChange(of: isPresented) { _, shown in
                if !shown { tip.invalidate(reason: .tipClosed) }
            }
            .task(id: tip.id) {
                for await shouldDisplay in tip.shouldDisplayUpdates {
                    isUnread = shouldDisplay
                }
            }
            .onDisappear {
                pending?.cancel()
                intent.exit()
            }
    }

    private func hoverChanged(_ inside: Bool) {
        pending?.cancel()
        guard inside, isUnread else {
            intent.exit()
            return
        }
        let deadline = intent.enter(at: .now)
        pending = Task { @MainActor in
            try? await Task.sleep(until: deadline.instant, clock: .continuous)
            if !Task.isCancelled, intent.isDue(deadline, at: .now) {
                isPresented = true
            }
        }
    }
}

/// The tip in the app's own colors, with a close button from the theme kit.
private struct ThemedTipViewStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        ThemedTipCard(configuration: configuration)
    }
}

private struct ThemedTipCard: View {
    let configuration: TipViewStyleConfiguration
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                configuration.title?
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.text.color)
                configuration.message?
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                configuration.tip.invalidate(reason: .tipClosed)
                dismiss()
            } label: {
                Label("Close tip", systemImage: "xmark")
            }
            .buttonStyle(.themeIcon)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(Theme.raised.color)
    }
}
