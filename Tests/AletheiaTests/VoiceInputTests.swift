import XCTest
import SwiftUI
import AppKit
import Speech
@testable import Aletheia

@MainActor
final class FakeVoiceInput: VoiceInput {
    var isOnDeviceSupported = true
    var authorization: VoiceAuthorization = .authorized
    var authorizationAfterRequest: VoiceAuthorization = .authorized
    private(set) var requestCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    var startError: Error?
    private var onPartial: ((String) -> Void)?
    private var onFinish: (() -> Void)?

    func requestAuthorization() async -> VoiceAuthorization {
        requestCount += 1
        authorization = authorizationAfterRequest
        return authorization
    }

    func start(onPartial: @escaping (String) -> Void, onFinish: @escaping () -> Void) throws {
        if let startError { throw startError }
        startCount += 1
        self.onPartial = onPartial
        self.onFinish = onFinish
    }

    func stop() { stopCount += 1 }
    func cancel() { cancelCount += 1; onPartial = nil; onFinish = nil }

    func hear(_ text: String) { onPartial?(text) }
    func finish() { onFinish?() }
}

@MainActor
final class VoiceInputTests: XCTestCase {
    // MARK: Mic visibility

    func testMicVisibilityAcrossEveryInput() {
        for supported in [true, false] {
            for auth in [VoiceAuthorization.notDetermined, .authorized, .denied] {
                for sending in [true, false] {
                    for recording in [true, false] {
                        let expected = supported && auth != .denied && !sending && !recording
                        XCTAssertEqual(
                            VoiceInputPolicy.showsMic(
                                onDeviceSupported: supported, authorization: auth,
                                isSending: sending, isSessionRecording: recording
                            ),
                            expected,
                            "supported=\(supported) auth=\(auth) sending=\(sending) recording=\(recording)"
                        )
                    }
                }
            }
        }
        // Spot checks that read as the rule.
        XCTAssertTrue(VoiceInputPolicy.showsMic(onDeviceSupported: true, authorization: .notDetermined, isSending: false, isSessionRecording: false))
        XCTAssertFalse(VoiceInputPolicy.showsMic(onDeviceSupported: false, authorization: .authorized, isSending: false, isSessionRecording: false))
    }

    func testPermissionsCombineWithAnyRefusalWinning() {
        typealias A = VoiceAuthorization
        XCTAssertEqual(VoiceInputPolicy.combine(microphone: .authorized, speech: .authorized), .authorized)
        XCTAssertEqual(VoiceInputPolicy.combine(microphone: .authorized, speech: .denied), .denied)
        XCTAssertEqual(VoiceInputPolicy.combine(microphone: .denied, speech: .notDetermined), .denied)
        XCTAssertEqual(VoiceInputPolicy.combine(microphone: .authorized, speech: .notDetermined), .notDetermined)
        XCTAssertEqual(VoiceInputPolicy.combine(microphone: .notDetermined, speech: .notDetermined), .notDetermined)
    }

    func testOnlyEscapeCancels() {
        XCTAssertTrue(VoiceInputPolicy.isCancelKey(keyCode: 53))
        XCTAssertFalse(VoiceInputPolicy.isCancelKey(keyCode: 36))
    }

    // MARK: Real recognizer

    func testRealRecognizerRequestRequiresOnDeviceAndStreamsPartials() {
        let request = SpeechVoiceInput.makeRequest()
        XCTAssertTrue(request.requiresOnDeviceRecognition)
        XCTAssertTrue(request.shouldReportPartialResults)
    }

    func testRealRecognizerNeverClaimsSupportWithoutOnDevice() {
        let input = SpeechVoiceInput()
        let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer()
        let expected = recognizer.map { $0.isAvailable && $0.supportsOnDeviceRecognition } ?? false
        XCTAssertEqual(input.isOnDeviceSupported, expected)
    }

    // MARK: Draft merging

    func testDraftMerging() {
        XCTAssertEqual(VoiceDraft.merged(base: "", partial: "hello there"), "hello there")
        XCTAssertEqual(VoiceDraft.merged(base: "  \n", partial: "hello"), "hello")
        XCTAssertEqual(VoiceDraft.merged(base: "What did", partial: "they say"), "What did they say")
        XCTAssertEqual(VoiceDraft.merged(base: "What did ", partial: "they say"), "What did they say")
        XCTAssertEqual(VoiceDraft.merged(base: "What did", partial: "  they say \n"), "What did they say")
        XCTAssertEqual(VoiceDraft.merged(base: "Keep this", partial: ""), "Keep this")
        XCTAssertEqual(VoiceDraft.merged(base: "Keep this", partial: "  "), "Keep this")
    }

    // MARK: Press, hold, release

    private func makeDictation(_ fake: FakeVoiceInput) -> (VoiceDictation, DraftBox) {
        (VoiceDictation(input: fake), DraftBox())
    }

    final class DraftBox { var text = "" }

    func testPressStartsHoldStreamsPartialsAndReleaseStops() async {
        let fake = FakeVoiceInput()
        let (dictation, box) = makeDictation(fake)
        box.text = "Ask about"

        await dictation.press(currentDraft: box.text) { box.text = $0 }
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertTrue(dictation.isRecording)
        XCTAssertEqual(fake.stopCount, 0)

        fake.hear("the")
        XCTAssertEqual(box.text, "Ask about the")
        fake.hear("the last session")
        XCTAssertEqual(box.text, "Ask about the last session", "partials replace each other, never stack")

        dictation.release()
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertFalse(dictation.isRecording)

        // The final text still lands after release; nothing is sent.
        fake.hear("the last session went")
        XCTAssertEqual(box.text, "Ask about the last session went")
        fake.finish()
        fake.hear("ignored once finished")
        XCTAssertEqual(box.text, "Ask about the last session went")
        XCTAssertEqual(fake.cancelCount, 0)
    }

    func testEscapeCancelsAndRestoresTheDraft() async {
        let fake = FakeVoiceInput()
        let (dictation, box) = makeDictation(fake)
        box.text = "Original draft"

        await dictation.press(currentDraft: box.text) { box.text = $0 }
        fake.hear("some words")
        XCTAssertEqual(box.text, "Original draft some words")

        dictation.cancel()
        XCTAssertEqual(box.text, "Original draft")
        XCTAssertEqual(fake.cancelCount, 1)
        XCTAssertFalse(dictation.isRecording)

        fake.hear("late partial")
        XCTAssertEqual(box.text, "Original draft", "a cancelled take writes nothing more")
    }

    func testEscapeAfterReleaseWhileFinishingStillDiscardsTheUtterance() async {
        let fake = FakeVoiceInput()
        let (dictation, box) = makeDictation(fake)
        await dictation.press(currentDraft: "") { box.text = $0 }
        fake.hear("hello")
        dictation.release()
        dictation.cancel()
        XCTAssertEqual(box.text, "")
    }

    func testDetachStopsWritingWithoutRestoring() async {
        let fake = FakeVoiceInput()
        let (dictation, box) = makeDictation(fake)
        await dictation.press(currentDraft: "") { box.text = $0 }
        fake.hear("sent already")
        box.text = ""   // the draft was sent
        dictation.detach()
        fake.hear("sent already, more")
        XCTAssertEqual(box.text, "")
    }

    func testFirstPressAsksForPermissionAndDoesNotRecord() async {
        let fake = FakeVoiceInput()
        fake.authorization = .notDetermined
        let (dictation, box) = makeDictation(fake)
        await dictation.press(currentDraft: "") { box.text = $0 }
        XCTAssertEqual(fake.requestCount, 1)
        XCTAssertEqual(fake.startCount, 0)
        XCTAssertEqual(dictation.authorization, .authorized)

        await dictation.press(currentDraft: "") { box.text = $0 }
        XCTAssertEqual(fake.requestCount, 1, "asked only once")
        XCTAssertEqual(fake.startCount, 1)
    }

    func testDeniedPermissionHidesTheMicFromThenOn() async {
        let fake = FakeVoiceInput()
        fake.authorization = .notDetermined
        fake.authorizationAfterRequest = .denied
        let (dictation, box) = makeDictation(fake)
        XCTAssertTrue(dictation.showsMic(isSending: false, isSessionRecording: false))
        await dictation.press(currentDraft: "") { box.text = $0 }
        XCTAssertFalse(dictation.showsMic(isSending: false, isSessionRecording: false))
        await dictation.press(currentDraft: "") { box.text = $0 }
        XCTAssertEqual(fake.startCount, 0)
        XCTAssertEqual(fake.requestCount, 1)
    }

    func testUnsupportedOnDeviceNeverStarts() async {
        let fake = FakeVoiceInput()
        fake.isOnDeviceSupported = false
        let (dictation, box) = makeDictation(fake)
        XCTAssertFalse(dictation.showsMic(isSending: false, isSessionRecording: false))
        await dictation.press(currentDraft: "") { box.text = $0 }
        XCTAssertEqual(fake.startCount, 0)
        XCTAssertEqual(fake.requestCount, 0)
    }

    func testStartFailureLeavesTheDraftAloneAndAllowsAnotherTry() async {
        struct Boom: Error {}
        let fake = FakeVoiceInput()
        fake.startError = Boom()
        let (dictation, box) = makeDictation(fake)
        box.text = "keep"
        await dictation.press(currentDraft: box.text) { box.text = $0 }
        XCTAssertFalse(dictation.isRecording)
        XCTAssertEqual(box.text, "keep")
        fake.startError = nil
        await dictation.press(currentDraft: box.text) { box.text = $0 }
        XCTAssertTrue(dictation.isRecording)
    }

    // MARK: Hosted

    private struct Host: View {
        let fake: FakeVoiceInput
        var isSending = false
        var isSessionRecording = false
        @State private var messages: [ChatMessage] = []

        var body: some View {
            ChatPaneView(
                title: "this session",
                messages: $messages,
                isSending: isSending,
                onSend: { _ in },
                isSessionRecording: isSessionRecording,
                voiceInput: fake
            )
            .frame(width: 520, height: 420)
        }
    }

    private var keepAlive: [NSWindow] = []

    private func hostedLayout<V: View>(_ root: V) -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: root)
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        keepAlive.append(window)
        return hosting
    }

    private func hasMic<V: View>(_ root: V) -> Bool {
        containsMic(hostedLayout(root))
    }

    private func findMarker(_ view: NSView) -> VoiceMicMarkerView? {
        if let m = view as? VoiceMicMarkerView { return m }
        for sub in view.subviews { if let m = findMarker(sub) { return m } }
        return nil
    }

    private func findTextView(_ view: NSView) -> ThemeTextAreaTextView? {
        if let t = view as? ThemeTextAreaTextView { return t }
        for sub in view.subviews { if let t = findTextView(sub) { return t } }
        return nil
    }

    /// Space between the end of the wrapping column and the view's right edge.
    private func rightGap(_ textView: ThemeTextAreaTextView) -> CGFloat {
        textView.frame.width - (textView.textContainerOrigin.x + textView.textContainer!.containerSize.width)
    }

    func testMicReservesRoomInsideTheBoxAndTextNeverRunsUnderIt() throws {
        let hosting = hostedLayout(Host(fake: FakeVoiceInput()))
        let textView = try XCTUnwrap(findTextView(hosting))
        XCTAssertGreaterThanOrEqual(rightGap(textView), ChatComposerLayout.accessoryWidth, "the right inset is at least the accessory width")

        textView.string = String(repeating: "a long question about the session ", count: 20)
        textView.didChangeText()
        hosting.layoutSubtreeIfNeeded()
        let layout = try XCTUnwrap(textView.layoutManager)
        let used = layout.usedRect(for: textView.textContainer!)
        let textRight = textView.textContainerOrigin.x + used.maxX
        XCTAssertLessThanOrEqual(textRight, textView.frame.width - ChatComposerLayout.accessoryWidth + 0.5, "wrapped text stops before the icon")
    }

    func testNoRoomIsReservedWhenThereIsNoMic() throws {
        let fake = FakeVoiceInput()
        fake.isOnDeviceSupported = false
        let hosting = hostedLayout(Host(fake: fake))
        let textView = try XCTUnwrap(findTextView(hosting))
        XCTAssertEqual(rightGap(textView), ThemeTextAreaMetrics.textContainerInset.width, accuracy: 0.5)
    }

    func testHostedMicSitsInsideTheBoxFrame() throws {
        let hosting = hostedLayout(Host(fake: FakeVoiceInput()))
        let textView = try XCTUnwrap(findTextView(hosting))
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        let marker = try XCTUnwrap(findMarker(hosting))
        let box = hosting.convert(scroll.bounds, from: scroll)
        let mic = hosting.convert(marker.bounds, from: marker)
        XCTAssertTrue(box.insetBy(dx: -0.5, dy: -0.5).contains(mic), "mic \(mic) should lie inside the box \(box)")
        XCTAssertGreaterThan(mic.midX, box.midX, "at the trailing edge")
    }

    func testContainerWidthKeepsTrailingRoom() {
        let inset = ThemeTextAreaMetrics.textContainerInset.width
        XCTAssertEqual(ThemeTextAreaMetrics.containerWidth(forViewWidth: 300, trailingInset: 0), 300 - 2 * inset)
        XCTAssertEqual(ThemeTextAreaMetrics.containerWidth(forViewWidth: 300, trailingInset: 40), 300 - 2 * inset - 40)
        XCTAssertEqual(ThemeTextAreaMetrics.containerWidth(forViewWidth: 10, trailingInset: 400), 1)
    }

    private func containsMic(_ view: NSView) -> Bool {
        view is VoiceMicMarkerView || view.subviews.contains { containsMic($0) }
    }

    func testHostedChatShowsTheMicWhenAvailableAndNoneWhenNot() {
        let available = FakeVoiceInput()
        XCTAssertTrue(hasMic(Host(fake: available)), "positive control: the mic renders when supported")

        let unavailable = FakeVoiceInput()
        unavailable.isOnDeviceSupported = false
        XCTAssertFalse(hasMic(Host(fake: unavailable)), "no mic when on-device recognition is unavailable")
    }

    func testHostedChatHidesTheMicWhileSendingRecordingOrDenied() {
        XCTAssertFalse(hasMic(Host(fake: FakeVoiceInput(), isSending: true)))
        XCTAssertFalse(hasMic(Host(fake: FakeVoiceInput(), isSessionRecording: true)))
        let denied = FakeVoiceInput()
        denied.authorization = .denied
        XCTAssertFalse(hasMic(Host(fake: denied)))
    }
}
