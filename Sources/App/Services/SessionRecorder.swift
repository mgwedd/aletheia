import Foundation

enum RecordingState: Equatable {
    case idle
    case recording(startedAt: Date)
    case error(String)
}

/// Pure duration logic, so the "did you forget to stop?" threshold is testable
/// without a running recorder.
enum RecordingLimit {
    /// A therapy hour runs ~50 min; past 90 the session was almost certainly
    /// meant to end and the mic is still open.
    static let reminderThreshold: TimeInterval = 90 * 60

    /// The alert raised when the threshold passes.
    enum Alert {
        static let title = "Still recording"
        static let keep = "Keep Recording"
        static let stop = "Stop Now"
    }

    static func shouldRemind(elapsed: TimeInterval, threshold: TimeInterval = reminderThreshold) -> Bool {
        elapsed >= threshold
    }
}

/// One recording at a time: why a new one can't begin, or nil when it can.
enum RecordingStartPolicy {
    static func refusal(isRecording: Bool, isStarting: Bool, activePatientName: String?) -> String? {
        if isRecording {
            let whose = activePatientName.map { "\($0)'s session" } ?? "Another session"
            return "\(whose) is still recording. Stop that recording before starting a new one."
        }
        if isStarting { return "A recording is already starting." }
        return nil
    }
}

/// Elapsed recording time that stops while paused: the time since start,
/// minus every paused span (including one still open).
struct RecordingClock: Equatable {
    private(set) var startedAt: Date
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?

    init(startedAt: Date) { self.startedAt = startedAt }

    mutating func pause(at now: Date) {
        if pausedAt == nil { pausedAt = now }
    }

    mutating func resume(at now: Date) {
        guard let pausedAt else { return }
        pausedTotal += max(0, now.timeIntervalSince(pausedAt))
        self.pausedAt = nil
    }

    func elapsed(at now: Date) -> TimeInterval {
        let end = pausedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - pausedTotal)
    }
}

/// Notices a call track that never carries sound. System-audio capture can open
/// without error and still deliver only silence (the call is played by a
/// process the stream can't see, or the output route isn't the one captured),
/// so nothing else would tell the therapist the other side isn't being
/// recorded. Only "never heard anything" counts: a patient who is quiet for a
/// while mid-session must not trip it.
struct CallAudioWatch: Equatable {
    /// How long a recording may run, unpaused, before silence is flagged.
    static let defaultGrace: TimeInterval = 90
    /// Meter position (0...1, see `AudioLevel`) that counts as sound.
    static let audibleLevel: Float = 0.02

    let grace: TimeInterval
    private(set) var heardSound = false
    private(set) var listened: TimeInterval = 0

    init(grace: TimeInterval = CallAudioWatch.defaultGrace) { self.grace = grace }

    /// True once `grace` seconds have been listened to with no sound at all.
    var isSilent: Bool { !heardSound && listened >= grace }

    /// Feed the latest raw call level every poll; `dt` is the time it covers.
    mutating func observe(level: Float, dt: TimeInterval) {
        guard !heardSound, dt > 0 else { return }
        if level.isFinite, level > Self.audibleLevel {
            heardSound = true
        } else {
            listened += dt
        }
    }

    mutating func reset() {
        heardSound = false
        listened = 0
    }
}

/// The smoothed live input levels (0...1) shown on the recording panel. A
/// separate observable object, so the ~15 Hz updates redraw only the meters
/// rather than every view that observes the recorder.
@MainActor
final class RecordingLevels: ObservableObject {
    @Published fileprivate(set) var mic: Float = 0
    @Published fileprivate(set) var call: Float = 0
}

/// Coordinates the two audio captures (mic + call) that make up a session
/// recording. They're kept as two separate files rather than mixed down to
/// one, which has a nice side effect: the transcript can label lines by
/// source ("You" vs "Call audio") instead of a single blended track.
@MainActor
final class SessionRecorder: ObservableObject {
    /// Which session a recording is writing into. Held so a global control (the
    /// menu-bar item) can name what's recording and route back to it, and so a
    /// session view knows whether *it* is the one recording.
    struct ActiveRecording: Equatable {
        let sessionID: UUID
        let patientID: UUID
        let patientName: String
        let patientSlug: String
        let sessionFolder: String

        init(
            sessionID: UUID,
            patientID: UUID,
            patientName: String,
            patientSlug: String,
            sessionFolder: String
        ) {
            self.sessionID = sessionID
            self.patientID = patientID
            self.patientName = patientName
            self.patientSlug = patientSlug
            self.sessionFolder = sessionFolder
        }
    }

    @Published private(set) var state: RecordingState = .idle
    /// True from the moment `start()` is accepted until it is recording or has
    /// failed: asking for permission and opening the captures takes a moment,
    /// and a second start in that window must not open them twice.
    @Published private(set) var isStarting = false
    /// Recording, or about to be.
    var isBusy: Bool { isRecording || isStarting }
    /// True while recording is paused (captures still running, buffers dropped).
    @Published private(set) var isPaused = false
    /// Drives the elapsed-time display; frozen while paused.
    private var clock: RecordingClock?
    /// The session currently being recorded, or nil when idle.
    @Published private(set) var active: ActiveRecording?
    /// Set once when a recording has run past `RecordingLimit.reminderThreshold`,
    /// so the UI can ask whether the therapist forgot to end the session. The
    /// view clears it when the user answers.
    @Published var longRunningReminder = false
    /// How long a recording runs before the reminder; tests shorten it.
    var reminderThreshold: TimeInterval = RecordingLimit.reminderThreshold
    /// True when the call track has stayed silent since the recording began (see
    /// `CallAudioWatch`), so the UI can say the other side isn't being captured.
    @Published private(set) var callAudioSilent = false
    private var callWatch = CallAudioWatch()
    /// Called after a recording has been stopped and saved (not when sealing it
    /// failed), with the session it belonged to.
    var onStopped: ((ActiveRecording) -> Void)?
    /// Called once when a recording passes `RecordingLimit.reminderThreshold`,
    /// whatever screen (if any) is showing.
    var onLongRunning: ((ActiveRecording) -> Void)?
    /// Called when something the user must be told about happens outside the
    /// recording screen: a finished recording that couldn't be encrypted yet, or a
    /// microphone that couldn't be restarted. The app shows it as a banner.
    var onNotice: ((SecurityAlert) -> Void)?
    /// Why call audio isn't being captured for the current recording (it never
    /// started, or stopped part-way), or nil when it's fine. Shown on the
    /// recording screen so a mic-only session is never a silent surprise.
    @Published private(set) var callAudioProblem: String?
    private var lastCallAudioStart = CallAudioDiagnostics.StartResult.notTried

    let recordingHealth = RecordingHealth()
    /// Live mic / call-audio levels for the meters; zero unless actively recording.
    let levels = RecordingLevels()
    private let mic = MicRecorder()
    private let systemAudio = SystemAudioCapture()
    /// Keeps Record from asking for call-audio access; only setup does.
    private var callAudioPolicy = CallAudioStartPolicy()
    private var reminderTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var micSmoother = AudioLevelSmoother()
    private var callSmoother = AudioLevelSmoother()
    /// Meter refresh rate: polled on a timer, never per audio buffer.
    private static let levelPollInterval: TimeInterval = 1.0 / 15.0

    /// Seals the finished recordings when encryption is on. Captured at
    /// `start()` and applied in `stop()` so the audio never lands as plaintext
    /// on an encrypted folder (beyond the live-recording window, by design).
    private var protector: FileProtector = .passthrough
    private var micURL: URL?
    private var callURL: URL?

    /// Root directory for audio staging.
    var stagingDirectoryURL: URL
    private(set) var currentStagingDir: URL?
    private(set) var stagingMicURL: URL?
    private(set) var stagingCallURL: URL?
    /// The session whose staging folder is in use (from the start of `start()`
    /// until its files are finalized), for the launch sweep to skip.
    private(set) var stagingSessionID: UUID?

    /// Injected hook for testing recording start without real audio hardware.
    var audioCaptureStartOverride: ((_ stagingMicURL: URL, _ stagingCallURL: URL) async throws -> Void)?

    init(stagingDirectoryURL: URL = Store.stagingDirectoryURL) {
        self.stagingDirectoryURL = stagingDirectoryURL
        // Runs on the audio thread; hop to the main actor to raise the notice.
        mic.onRestartFailed = { [weak self] in
            Task { @MainActor [weak self] in self?.micRestartFailed() }
        }
    }

    /// The microphone changed mid-recording and capture couldn't be restarted.
    func micRestartFailed() {
        onNotice?(.microphoneRestartFailed)
    }

    /// The Stop under way, so a second Stop (or the quit) waits for its seal
    /// instead of sealing the same files again.
    private var stopping: Task<Void, Never>?
    /// Set once the app has started quitting: the recording is still finalized,
    /// but `onStopped` doesn't fire, so no transcription starts on the way out.
    private var isQuitting = false

    /// Why a new recording may not start because of the license, or nil. Set by the app.
    var licenseRefusal: (() -> String?)?

    /// Files are open (recording, paused, stopped by a capture error, or
    /// still being finalized by a Stop).
    var hasOpenRecording: Bool { stagingMicURL != nil || micURL != nil }

    /// Why `start` would refuse right now (the license, or another recording
    /// in the way), or nil. Asked before the consent sheet, so a refused start
    /// saves no consent.
    func startRefusal() -> String? {
        if let refusal = licenseRefusal?() { return refusal }
        return RecordingStartPolicy.refusal(
            isRecording: isRecording, isStarting: isStarting, activePatientName: active?.patientName)
    }

    /// Starts recording. Returns nil once recording, or why it isn't: another
    /// recording is in the way (which is left untouched), or this one failed to
    /// start (also left in `state`).
    @discardableResult
    func start(micURL: URL, callURL: URL, context: ActiveRecording, protector: FileProtector = .passthrough) async -> String? {
        // A lapsed license stops a *new* recording only; stopping, transcribing and
        // reading what exists never ask. Unset (nil) allows everything.
        if let refusal = licenseRefusal?() { return refusal }
        if let refusal = RecordingStartPolicy.refusal(
            isRecording: isRecording, isStarting: isStarting, activePatientName: active?.patientName
        ) {
            return refusal
        }
        isStarting = true
        defer { isStarting = false }

        let stagingDir = stagingDirectoryURL.appendingPathComponent(context.sessionID.uuidString, isDirectory: true)
        let stageMic = stagingDir.appendingPathComponent("mic.caf")
        let stageCall = stagingDir.appendingPathComponent("call.caf")
        // Claimed before anything touches the folder, so the launch sweep leaves it alone.
        stagingSessionID = context.sessionID
        do {
            // An earlier recording of this session still staged (it couldn't be sealed then):
            // put it in place first, so this start can't overwrite or clear it.
            for (stage, dest) in [(stageMic, micURL), (stageCall, callURL)] {
                try protector.sealLargeFile(from: stage, to: dest)
            }
            try PrivateStaging.ensurePrivateDirectory(stagingDir)
            try? PrivateStaging.ensureBackupExcludedRoot(stagingDirectoryURL)
        } catch {
            stagingSessionID = nil
            let message = "Couldn't prepare the recording folder: \(error.localizedDescription)"
            state = .error(message)
            return message
        }

        if let audioCaptureStartOverride {
            do {
                try await audioCaptureStartOverride(stageMic, stageCall)
                self.protector = protector
                self.currentStagingDir = stagingDir
                self.stagingMicURL = stageMic
                self.stagingCallURL = stageCall
                self.micURL = micURL
                self.callURL = callURL
                isPaused = false
                active = context
                let started = Date()
                clock = RecordingClock(startedAt: started)
                state = .recording(startedAt: started)
                startReminderTimer()
                return nil
            } catch {
                try? FileManager.default.removeItem(at: stagingDir)
                stagingSessionID = nil
                active = nil
                state = .error(error.localizedDescription)
                return error.localizedDescription
            }
        }

        let micGranted = await MicRecorder.requestPermission()
        guard micGranted else {
            stagingSessionID = nil
            let message = MicRecorderError.permissionDenied.localizedDescription
            state = .error(message)
            return message
        }

        systemAudio.onError = { [weak self] error in
            guard let self else { return }
            self.recordingHealth.recordSystemAudioDisruption(error.localizedDescription)
            if self.callAudioProblem == nil { self.callAudioProblem = error.localizedDescription }
            // System audio stream disruption (DRM, permission yank, display disconnect)
            // is non-fatal to the session if the microphone track is still recording.
            if !self.mic.isRunning {
                self.state = .error("Recording interrupted: \(error.localizedDescription)")
            }
        }
        mic.onDisruption = { [weak self] message in
            guard let self else { return }
            if !self.mic.isRunning && !self.systemAudio.isRunning {
                self.state = .error(message)
            }
        }

        recordingHealth.reset()
        callAudioProblem = nil
        lastCallAudioStart = .notTried
        do {
            try mic.start(to: stageMic)
            // System audio capture is best-effort — if system audio fails to start,
            // session recording still continues with the microphone track.
            let grantStore = CallAudioGrantStore.standard
            if callAudioPolicy.shouldAttempt(
                preflight: SystemAudioCapture.checkPermission(),
                confirmedBefore: grantStore.isConfirmed
            ) {
                do {
                    try await systemAudio.start(to: stageCall)
                    callAudioPolicy.recordAttempt(succeeded: true)
                    grantStore.confirm()
                    lastCallAudioStart = .started
                } catch {
                    callAudioPolicy.recordAttempt(succeeded: false)
                    lastCallAudioStart = .failed(CallAudioDiagnostics.describe(error))
                    callAudioProblem = error.localizedDescription
                    if let captureError = error as? SystemAudioCaptureError, captureError == .permissionDenied {
                        grantStore.clear()
                    }
                    recordingHealth.recordSystemAudioDisruption(error.localizedDescription)
                }
            } else {
                lastCallAudioStart = .skipped
                callAudioProblem = CallAudioStartPolicy.skippedMessage
                recordingHealth.recordSystemAudioDisruption(CallAudioStartPolicy.skippedMessage)
            }
            self.protector = protector
            self.currentStagingDir = stagingDir
            self.stagingMicURL = stageMic
            self.stagingCallURL = stageCall
            self.micURL = micURL
            self.callURL = callURL
            isPaused = false
            active = context
            let started = Date()
            clock = RecordingClock(startedAt: started)
            state = .recording(startedAt: started)
            startReminderTimer()
            callWatch.reset()
            callAudioSilent = false
            startLevelPolling()
            return nil
        } catch {
            mic.stop()
            await systemAudio.stop()
            try? FileManager.default.removeItem(at: stagingDir)
            stagingSessionID = nil
            active = nil
            state = .error(error.localizedDescription)
            return error.localizedDescription
        }
    }

    /// Pause both captures without ending the session. The mic and call streams
    /// keep running but stop writing, so the recording resumes as one continuous
    /// file with the paused span omitted.
    func pause() {
        guard isRecording, !isPaused else { return }
        mic.isPaused = true
        systemAudio.isPaused = true
        isPaused = true
        clock?.pause(at: Date())
        resetLevels()
    }

    /// Resume writing after a `pause()`.
    func resume() {
        guard isRecording, isPaused else { return }
        mic.isPaused = false
        systemAudio.isPaused = false
        isPaused = false
        clock?.resume(at: Date())
    }

    func stop() async {
        // A second Stop while the first is still sealing waits for it rather
        // than sealing the same files again or reporting the recording twice.
        if let stopping {
            await stopping.value
            return
        }
        let task = Task { await self.finishRecording() }
        stopping = task
        await task.value
        stopping = nil
    }

    /// Quitting: waits out a start already under way, then stops and finalizes
    /// whatever is still open (a recording, one a capture error ended, or one a
    /// Stop is already sealing). Returns at once when nothing was recording.
    func shutDown() async {
        isQuitting = true
        while isStarting { try? await Task.sleep(nanoseconds: 20_000_000) }
        guard hasOpenRecording else { return }
        await stop()
    }

    private func finishRecording() async {
        reminderTask?.cancel()
        reminderTask = nil
        stopLevelPolling()
        callWatch.reset()
        callAudioSilent = false
        mic.stop()
        await systemAudio.stop()
        // After the stream is down, so a late stream error can't set it again.
        callAudioProblem = nil
        isPaused = false
        clock = nil
        let sealError = await finalizeRecordings()
        let finished = active
        active = nil
        stagingSessionID = nil
        currentStagingDir = nil
        stagingMicURL = nil
        stagingCallURL = nil
        micURL = nil
        callURL = nil
        state = sealError.map { .error($0) } ?? .idle
        // The error state has no screen of its own, so tell the user here.
        if sealError != nil { onNotice?(.recordingEncryptionDeferred) }
        if let finished, sealError == nil, !isQuitting { onStopped?(finished) }
    }

    /// Finalizes recordings from staging to the session destination folder:
    /// sealed into place when encryption is on, moved when it's off. Runs off
    /// the main actor (chunked streaming, bounded memory). A recording that
    /// can't be sealed stays staged for the launch sweep, and the error is surfaced.
    private func finalizeRecordings() async -> String? {
        let protector = self.protector
        let pairs: [(stage: URL, dest: URL)] = [
            (stagingMicURL, micURL),
            (stagingCallURL, callURL)
        ].compactMap { stage, dest in
            guard let stage, let dest else { return nil }
            return (stage, dest)
        }
        let stagingDir = self.currentStagingDir

        return await Task.detached(priority: .utility) { () -> String? in
            var sealErrorMessage: String? = nil
            var kept = false

            for pair in pairs {
                guard FileManager.default.fileExists(atPath: pair.stage.path) else { continue }
                do {
                    try protector.sealLargeFile(from: pair.stage, to: pair.dest)
                    try? FileManager.default.removeItem(at: pair.stage)
                } catch {
                    // Never dropped, and never left as plaintext in the session folder:
                    // it stays in the private staging folder and the next launch seals it.
                    kept = true
                    sealErrorMessage = "The recording was kept but couldn't be encrypted yet (\(error.localizedDescription)). It's added to the session, encrypted, the next time Aletheia opens."
                }
            }

            if let stagingDir, !kept {
                try? FileManager.default.removeItem(at: stagingDir)
            }

            return sealErrorMessage
        }.value
    }

    /// After the reminder threshold, flag that the session has likely been left
    /// recording. Fires once; `stop()` cancels it.
    private func startReminderTimer() {
        reminderTask?.cancel()
        longRunningReminder = false
        let threshold = reminderThreshold
        reminderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(threshold * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.isRecording else { return }
            self.longRunningReminder = true
            if let active = self.active { self.onLongRunning?(active) }
        }
    }

    /// Starts the ~15 Hz poll that turns the recorders' latest raw levels into
    /// the smoothed values the meters show. `stop()` cancels it.
    private func startLevelPolling() {
        levelTask?.cancel()
        resetLevels()
        let interval = Self.levelPollInterval
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.updateLevels(dt: Float(interval))
            }
        }
    }

    private func stopLevelPolling() {
        levelTask?.cancel()
        levelTask = nil
        resetLevels()
    }

    /// Paused shows the meters at zero; otherwise smooths the latest raw levels
    /// and feeds `CallAudioWatch` with the unpaused poll interval.
    func updateLevels(dt: Float, rawMicLevel: Float? = nil, rawCallLevel: Float? = nil) {
        guard isRecording else {
            // Recording ended some other way (e.g. a capture error): stop polling.
            stopLevelPolling()
            return
        }
        guard !isPaused else {
            resetLevels()
            return
        }
        let callTarget = rawCallLevel ?? systemAudio.levelSource.latest()
        callWatch.observe(level: callTarget, dt: TimeInterval(dt))
        if callAudioSilent != callWatch.isSilent { callAudioSilent = callWatch.isSilent }
        let micValue = micSmoother.update(target: rawMicLevel ?? mic.levelSource.latest(), dt: dt)
        let callValue = callSmoother.update(target: callTarget, dt: dt)
        // Skip identical values (e.g. steady silence) so idle meters don't republish.
        if levels.mic != micValue { levels.mic = micValue }
        if levels.call != callValue { levels.call = callValue }
    }

    /// Test seam: enters the `.recording` state without opening hardware audio
    /// devices so `updateLevels`, `pause`, `resume`, and `CallAudioWatch`
    /// wiring can be exercised deterministically.
    func beginSimulatedRecordingForTesting(
        startedAt: Date = Date(),
        grace: TimeInterval = CallAudioWatch.defaultGrace,
        stagingDir: URL? = nil,
        stagingMicURL: URL? = nil,
        stagingCallURL: URL? = nil,
        micURL: URL? = nil,
        callURL: URL? = nil,
        context: ActiveRecording? = nil,
        protector: FileProtector = .passthrough
    ) {
        self.currentStagingDir = stagingDir
        self.stagingMicURL = stagingMicURL
        self.stagingCallURL = stagingCallURL
        self.micURL = micURL
        self.callURL = callURL
        self.active = context
        self.protector = protector
        isPaused = false
        clock = RecordingClock(startedAt: startedAt)
        state = .recording(startedAt: startedAt)
        callWatch = CallAudioWatch(grace: grace)
        callAudioSilent = false
        resetLevels()
    }

    private func resetLevels() {
        micSmoother.reset()
        callSmoother.reset()
        if levels.mic != 0 { levels.mic = 0 }
        if levels.call != 0 { levels.call = 0 }
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// The current call-audio state for the debug panel and Doctor. Never prompts.
    func callAudioDiagnostics(grantStore: CallAudioGrantStore = .standard) -> CallAudioDiagnostics {
        let health = recordingHealth.snapshot
        return CallAudioDiagnostics(
            preflightGranted: SystemAudioCapture.checkPermission(),
            currentBuild: grantStore.build,
            confirmedBuild: grantStore.confirmedBuild,
            attemptedThisLaunch: callAudioPolicy.attempted,
            workedThisLaunch: callAudioPolicy.worked,
            lastStart: lastCallAudioStart,
            streamRunning: systemAudio.isRunning,
            streamDisrupted: systemAudio.isDisrupted,
            buffersReceived: systemAudio.buffersReceived,
            bytesWritten: systemAudio.bytesWritten,
            disruptions: health.systemAudioDisruptions,
            firstFailure: health.firstFailure
        )
    }

    /// Recorded time so far, not counting paused spans. 0 before `start` and
    /// after `stop`; after a capture error it keeps counting until `stop`.
    func elapsed(at now: Date = Date()) -> TimeInterval {
        clock?.elapsed(at: now) ?? 0
    }

    /// When the active recording began (for an elapsed-time display), or nil.
    var startedAt: Date? {
        if case .recording(let date) = state { return date }
        return nil
    }
}
