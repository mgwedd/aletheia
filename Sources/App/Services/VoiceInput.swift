import Foundation
import AVFoundation
import Speech

// Press-and-hold dictation for the Ask boxes. Everything is recognised on this
// Mac: the request requires on-device recognition, and when the recogniser
// can't do that the mic is not offered at all. There is no server fallback.
// (This is the Speech framework, not Apple Intelligence.)

/// Where microphone + speech-recognition permission stands, as one value.
enum VoiceAuthorization: Equatable {
    /// Not asked yet: the first press asks.
    case notDetermined
    case authorized
    /// Denied or restricted (by either permission): the mic stays hidden.
    case denied
}

/// Pure rules for the dictation button.
enum VoiceInputPolicy {
    /// Whether the mic is drawn at all. Never when on-device recognition isn't
    /// supported or permission was refused; not while a reply is being sent
    /// (the Stop button is there then) or a session is being recorded (the
    /// recorder owns the microphone).
    static func showsMic(
        onDeviceSupported: Bool,
        authorization: VoiceAuthorization,
        isSending: Bool,
        isSessionRecording: Bool
    ) -> Bool {
        onDeviceSupported && authorization != .denied && !isSending && !isSessionRecording
    }

    /// Combines the two permissions: any refusal wins, both granted is granted.
    static func combine(microphone: VoiceAuthorization, speech: VoiceAuthorization) -> VoiceAuthorization {
        if microphone == .denied || speech == .denied { return .denied }
        if microphone == .authorized && speech == .authorized { return .authorized }
        return .notDetermined
    }

    /// Esc (key code 53) cancels a recording.
    static func isCancelKey(keyCode: UInt16) -> Bool { keyCode == 53 }
}

/// Existing draft + what has been heard so far.
enum VoiceDraft {
    /// The partial text is appended to the draft the user had when they began
    /// holding, separated by one space. Partials replace each other, so this
    /// is always computed from the original draft, never the previous result.
    static func merged(base: String, partial: String) -> String {
        let spoken = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return base }
        if base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return spoken }
        if let last = base.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            return base + spoken
        }
        return base + " " + spoken
    }
}

/// The recogniser behind the mic. A fake stands in for tests.
@MainActor
protocol VoiceInput: AnyObject {
    /// True only when speech can be recognised on this Mac.
    var isOnDeviceSupported: Bool { get }
    var authorization: VoiceAuthorization { get }
    /// Asks for microphone and speech-recognition access (system prompts).
    func requestAuthorization() async -> VoiceAuthorization
    /// Starts listening. `onPartial` gets the full text heard so far, each time
    /// it changes, on the main actor; `onFinish` fires once when recognition is
    /// over (after `stop` or an error).
    func start(onPartial: @escaping (String) -> Void, onFinish: @escaping () -> Void) throws
    /// Stops listening; the recogniser then delivers its final text.
    func stop()
    /// Stops listening and drops everything, with no more callbacks.
    func cancel()
}

/// Drives a `VoiceInput` from a press-and-hold control and the draft binding.
@MainActor
final class VoiceDictation: ObservableObject {
    private let input: VoiceInput
    @Published private(set) var isRecording = false
    @Published private(set) var authorization: VoiceAuthorization
    @Published private(set) var onDeviceSupported: Bool

    private var isHeld = false
    private var baseDraft = ""
    /// Bumped when a take ends, so a late callback from it is ignored.
    private var generation = 0
    private var setDraft: ((String) -> Void)?

    init(input: VoiceInput) {
        self.input = input
        authorization = input.authorization
        onDeviceSupported = input.isOnDeviceSupported
    }

    func showsMic(isSending: Bool, isSessionRecording: Bool) -> Bool {
        VoiceInputPolicy.showsMic(
            onDeviceSupported: onDeviceSupported,
            authorization: authorization,
            isSending: isSending,
            isSessionRecording: isSessionRecording
        )
    }

    /// The pointer went down on the mic. The first time, this asks for
    /// permission and doesn't record (the hold is over by the time the user
    /// has answered the prompts).
    func press(currentDraft: String, setDraft: @escaping (String) -> Void) async {
        guard !isHeld, onDeviceSupported, authorization != .denied else { return }
        isHeld = true
        if authorization == .notDetermined {
            authorization = await input.requestAuthorization()
            isHeld = false
            return
        }
        begin(currentDraft: currentDraft, setDraft: setDraft)
    }

    /// The pointer came up: stop listening; the final text still lands.
    func release() {
        isHeld = false
        guard isRecording else { return }
        isRecording = false
        input.stop()
    }

    /// Esc: stop and put the draft back as it was before this hold.
    func cancel() {
        isHeld = false
        guard let write = setDraft else { return }
        let restore = baseDraft
        endTake()
        input.cancel()
        write(restore)
    }

    /// The draft was sent or replaced: stop writing into it.
    func detach() {
        isHeld = false
        guard setDraft != nil else { return }
        endTake()
        input.cancel()
    }

    private func begin(currentDraft: String, setDraft: @escaping (String) -> Void) {
        generation += 1
        let take = generation
        baseDraft = currentDraft
        self.setDraft = setDraft
        do {
            try input.start(
                onPartial: { [weak self] text in
                    guard let self, self.generation == take, let write = self.setDraft else { return }
                    write(VoiceDraft.merged(base: self.baseDraft, partial: text))
                },
                onFinish: { [weak self] in
                    guard let self, self.generation == take else { return }
                    self.endTake()
                }
            )
            isRecording = true
        } catch {
            endTake()
            isHeld = false
        }
    }

    private func endTake() {
        generation += 1
        isRecording = false
        setDraft = nil
    }
}

// MARK: - Apple Speech

/// On-device dictation through `SFSpeechRecognizer` fed by an `AVAudioEngine`
/// input tap.
@MainActor
final class SpeechVoiceInput: VoiceInput {
    private let recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    /// The one place a recognition request is made, so what it requires is
    /// tested: on-device only, partial results on.
    static func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        return request
    }

    var isOnDeviceSupported: Bool {
        guard let recognizer else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    var authorization: VoiceAuthorization {
        let speech: VoiceAuthorization
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = .authorized
        case .denied, .restricted: speech = .denied
        default: speech = .notDetermined
        }
        let microphone: VoiceAuthorization
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .authorized
        case .denied, .restricted: microphone = .denied
        default: microphone = .notDetermined
        }
        return VoiceInputPolicy.combine(microphone: microphone, speech: speech)
    }

    func requestAuthorization() async -> VoiceAuthorization {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        return authorization
    }

    private struct Unavailable: Error {}

    func start(onPartial: @escaping (String) -> Void, onFinish: @escaping () -> Void) throws {
        teardown()
        guard let recognizer, isOnDeviceSupported else { throw Unavailable() }
        generation += 1
        let take = generation

        let request = Self.makeRequest()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard let self, self.generation == take else { return }
                if let text { onPartial(text) }
                if done {
                    self.teardown()
                    onFinish()
                }
            }
        }
    }

    func stop() {
        stopCapture()
        request?.endAudio()
    }

    func cancel() {
        generation += 1
        teardown()
    }

    /// Stops the microphone and removes the tap; the recognition task goes on.
    private func stopCapture() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private func teardown() {
        stopCapture()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }
}
