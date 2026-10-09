import Foundation

/// The named steps a transcription moves through, so the UI can say what is
/// happening instead of showing one unexplained percentage.
enum TranscriptionStage: Equatable {
    /// Decrypting and resampling a recording (before whisper can read it).
    case preparing
    case transcribingMic
    case transcribingCall
    /// The text exists and is being written to the session folder. Past the
    /// point where a cancel could usefully stop anything.
    case saving

    var title: String {
        switch self {
        case .preparing: "Preparing audio"
        case .transcribingMic: "Transcribing mic"
        case .transcribingCall: "Transcribing call audio"
        case .saving: "Saving"
        }
    }

    /// Whether whisper is actually running (as opposed to setup or teardown),
    /// which is when the time estimate starts to mean something.
    var isTranscribing: Bool {
        self == .transcribingMic || self == .transcribingCall
    }
}

/// One progress report: the current stage and overall completion across every
/// track of the session (0...1).
struct TranscriptionProgress: Equatable {
    var stage: TranscriptionStage
    var fraction: Double
}

/// Pure progress arithmetic and wording, kept free of I/O so it is unit-testable.
enum TranscriptionProgressMath {
    /// Fewer than this many seconds of transcribing is too little data for a
    /// time estimate to be anything but noise.
    static let minimumSecondsForEstimate: TimeInterval = 10

    /// Maps one track's own 0...1 progress onto the whole session, where each
    /// of `trackCount` tracks owns an equal slice. A single-track session
    /// therefore still runs 0-100%.
    static func overall(trackIndex: Int, trackCount: Int, trackFraction: Double) -> Double {
        guard trackCount > 0 else { return 0 }
        let span = 1.0 / Double(trackCount)
        let clamped = min(max(trackFraction, 0), 1)
        return min(max((Double(trackIndex) + clamped) * span, 0), 1)
    }

    /// Estimated seconds left, from how long `fractionDone` of the work took.
    /// nil until there is enough data to say anything useful.
    static func remainingSeconds(elapsed: TimeInterval, fractionDone: Double) -> TimeInterval? {
        guard elapsed >= minimumSecondsForEstimate, fractionDone > 0.01, fractionDone < 1 else { return nil }
        return elapsed * (1 - fractionDone) / fractionDone
    }

    /// "about 2 min left" / "less than a minute left".
    static func remainingText(seconds: TimeInterval) -> String {
        if seconds < 60 { return "less than a minute left" }
        return "about \(Int((seconds / 60).rounded())) min left"
    }
}

/// The state of one session's transcription, as the UI sees it. A value type so
/// every rule (cancel, stage ordering, estimates) is testable without a
/// transcriber, a store, or a clock.
struct TranscriptionJob: Equatable {
    let startedAt: Date
    private(set) var progress = TranscriptionProgress(stage: .preparing, fraction: 0)
    /// Cancel was requested; the work is winding down.
    private(set) var isCancelling = false
    private var transcribingSince: Date?
    private var fractionAtTranscribingStart = 0.0

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// Folds in a progress report. Completion never moves backwards, `.saving`
    /// is final (a straggling report from the transcriber must not drag the
    /// card back to "Transcribing"), and nothing changes once cancelling.
    mutating func apply(_ update: TranscriptionProgress, now: Date) {
        guard !isCancelling, progress.stage != .saving else { return }
        if update.stage.isTranscribing, transcribingSince == nil {
            transcribingSince = now
            fractionAtTranscribingStart = max(progress.fraction, update.fraction)
        }
        progress = TranscriptionProgress(stage: update.stage, fraction: max(progress.fraction, update.fraction))
    }

    /// Cancel is offered until the text is being saved; after that the result
    /// is already final.
    var canCancel: Bool {
        !isCancelling && progress.stage != .saving
    }

    /// Marks the job cancelling. Returns false (and changes nothing) when
    /// cancelling is no longer possible.
    mutating func requestCancel() -> Bool {
        guard canCancel else { return false }
        isCancelling = true
        return true
    }

    /// Seconds left, measured only over the time whisper has been running so
    /// that decrypt/resample time doesn't inflate it.
    func remainingSeconds(now: Date) -> TimeInterval? {
        guard let transcribingSince, progress.stage.isTranscribing, !isCancelling else { return nil }
        return TranscriptionProgressMath.remainingSeconds(
            elapsed: now.timeIntervalSince(transcribingSince),
            fractionDone: progress.fraction - fractionAtTranscribingStart
        )
    }

    /// One-line status for compact surfaces (menu bar).
    var statusLine: String {
        isCancelling ? "Cancelling…" : "Transcribing… \(Int(progress.fraction * 100))%"
    }
}

/// How a transcription ended, held until the session screen picks it up (the
/// screen may not have been on display when it finished).
enum TranscriptionOutcome: Equatable {
    case completed
    /// Nothing was transcribed; the recording was kept. Carries the notice.
    case blank(notice: String)
    case cancelled
    case failed(message: String)
}
