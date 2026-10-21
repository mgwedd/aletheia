import SwiftUI
import AppKit

/// The round mic at the trailing edge of the chat composer: press and hold to
/// dictate, release to stop. Draws nothing at all when on-device recognition
/// isn't available, permission was refused, a reply is being sent, or a
/// session is being recorded (`VoiceInputPolicy.showsMic`).
struct VoiceMicControl: View {
    static let accessibilityIdentifier = "chat.voice.mic"
    static let tooltip = "Press and hold to record"

    @Binding var draft: String
    var isSending: Bool
    var isSessionRecording: Bool
    /// Changes when the draft is sent, so a late result can't refill the box.
    var resetToken: Int

    @StateObject private var dictation: VoiceDictation
    @State private var isPressed = false
    @State private var escMonitor: Any?

    init(
        draft: Binding<String>,
        isSending: Bool,
        isSessionRecording: Bool,
        resetToken: Int,
        input: VoiceInput?
    ) {
        _draft = draft
        self.isSending = isSending
        self.isSessionRecording = isSessionRecording
        self.resetToken = resetToken
        // Evaluated once, when the view first appears.
        _dictation = StateObject(wrappedValue: VoiceDictation(input: input ?? SpeechVoiceInput()))
    }

    var body: some View {
        Group {
            if dictation.showsMic(isSending: isSending, isSessionRecording: isSessionRecording) {
                MicButtonFace(isRecording: dictation.isRecording)
                    .background(VoiceMicMarker())
                    .gesture(hold)
                    .help(Self.tooltip)
                    .accessibilityElement()
                    .accessibilityLabel("Dictate")
                    .accessibilityHint(Text(Self.tooltip + ". Recognized on this Mac."))
                    .accessibilityIdentifier(Self.accessibilityIdentifier)
                    .accessibilityAddTraits(.isButton)
            }
        }
        .onChange(of: dictation.isRecording) { _, recording in
            recording ? installEscMonitor() : removeEscMonitor()
        }
        .onChange(of: resetToken) { _, _ in dictation.detach() }
        .onChange(of: isSending) { _, sending in if sending { dictation.detach() } }
        .onChange(of: isSessionRecording) { _, recording in if recording { dictation.detach() } }
        .onDisappear {
            dictation.detach()
            removeEscMonitor()
        }
    }

    /// Down starts, up stops. A zero-distance drag reports both.
    private var hold: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                isPressed = true
                let current = draft
                Task {
                    await dictation.press(currentDraft: current) { draft = $0 }
                    // Released while permission was being asked or the engine started.
                    if !isPressed { dictation.release() }
                }
            }
            .onEnded { _ in
                isPressed = false
                dictation.release()
            }
    }

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard VoiceInputPolicy.isCancelKey(keyCode: event.keyCode) else { return event }
            dictation.cancel()
            return nil
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }
}

/// The mic's look: a raised circle with a muted glyph; while held, the
/// recording fill with a soft pulse.
private struct MicButtonFace: View {
    let isRecording: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var pulse = false

    var body: some View {
        let side: CGFloat = 40
        ZStack {
            if isRecording {
                Circle()
                    .fill(Theme.recordingTint.color)
                    .frame(width: side, height: side)
                    .scaleEffect(pulse ? 1.35 : 1)
                    .opacity(pulse ? 0 : 0.9)
            }
            Circle()
                .fill(isRecording ? Theme.recordingFill.color : (isHovered ? Theme.hover.color : Theme.raised.color))
                .frame(width: side, height: side)
                .overlay(Circle().strokeBorder(isRecording ? Theme.recordingFill.color : Theme.line.color, lineWidth: 1))
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isRecording ? Theme.recordingInk.color : Theme.text.color)
        }
        .frame(width: side, height: side)
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isRecording)
        .onChange(of: isRecording, initial: true) { _, recording in
            guard recording, !reduceMotion else { pulse = false; return }
            pulse = false
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// An empty AppKit view behind the mic, so a hosted-view test can tell whether
/// the mic is in the hierarchy (SwiftUI's own nodes aren't visible to AppKit).
final class VoiceMicMarkerView: NSView {}

private struct VoiceMicMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> VoiceMicMarkerView { VoiceMicMarkerView() }
    func updateNSView(_ view: VoiceMicMarkerView, context: Context) {}
}
