import Foundation

/// What else is going on, as the background summary scheduler sees it.
struct DigestActivity: Equatable {
    var locked = false
    var recording = false
    var transcribing = false
    /// A note or a chat answer is running or waiting on the model.
    var modelBusy = false
    /// The user paused summaries.
    var userPaused = false
    var lowPowerMode = false
    var onBattery = false
    /// A build failed a short while ago (`DigestSchedulePolicy.failureBackoff`).
    var recentFailure = false
    /// "Prepare now": run despite the user's pause, battery, Low Power Mode
    /// and a recent failure (never despite a recording, the lock or other AI work).
    var preparingNow = false
}

/// Why summaries are not being prepared right now.
enum DigestPauseReason: Equatable {
    case locked, recording, transcribing, modelBusy, user, lowPowerMode, battery, failure

    /// The words after "Summaries: 62 of 100 ready · ".
    var text: String {
        switch self {
        case .locked: return "paused while Aletheia is locked"
        case .recording: return "paused while recording"
        case .transcribing: return "paused while transcribing"
        case .modelBusy: return "paused while the AI is working"
        case .user: return "paused"
        case .lowPowerMode: return "paused in Low Power Mode"
        case .battery: return "paused on battery"
        case .failure: return "paused after a problem, will try again soon"
        }
    }

    /// Whether "Prepare now" may run anyway.
    var canPrepareNow: Bool {
        switch self {
        case .user, .lowPowerMode, .battery, .failure: return true
        case .locked, .recording, .transcribing, .modelBusy: return false
        }
    }
}

/// The decisions behind background summaries (session digests), as pure
/// functions: when to run, when to pause, which sessions need one, in what
/// order, and what the status line says. `DigestScheduler` does the work.
enum DigestSchedulePolicy {
    /// Characters kept for instructions, notes and the question when judging
    /// whether a transcript, or a whole history, fits one prompt.
    static let promptOverhead = 6_000
    /// How long to wait after a failed build before trying again on its own.
    static let failureBackoff: TimeInterval = 600
    /// How long to wait before looking for new work after everything was ready.
    static let rescanInterval: TimeInterval = 900

    /// Why to pause, or nil to run. A recording, the lock, a transcription and
    /// other AI work always win: the summaries are background work. After those,
    /// the conservative defaults: the user's pause, Low Power Mode, battery and a
    /// recent failure, which "Prepare now" overrides.
    static func pauseReason(_ a: DigestActivity) -> DigestPauseReason? {
        if a.locked { return .locked }
        if a.recording { return .recording }
        if a.transcribing { return .transcribing }
        if a.modelBusy { return .modelBusy }
        if a.preparingNow { return nil }
        if a.userPaused { return .user }
        if a.lowPowerMode { return .lowPowerMode }
        if a.onBattery { return .battery }
        if a.recentFailure { return .failure }
        return nil
    }

    /// Whether a session needs a summary: it has a transcript, and either the
    /// transcript is too long to send whole (`room`) or its patient's history
    /// is (then the patient chat reads summaries), or it is too long for its
    /// note to read whole (`readsWhole` false, `LongSessionNote.readsWhole`). A
    /// short session of a short history never needs one: everything is read whole.
    static func needsSummary(
        transcriptCharacters: Int, historyCharacters: Int, room: Int, readsWhole: Bool = true
    ) -> Bool {
        transcriptCharacters > 0 && (transcriptCharacters > room || historyCharacters > room || !readsWhole)
    }

    /// One session waiting for its summary.
    struct Candidate: Equatable {
        let patientID: UUID
        let sessionID: UUID
        let date: Date
    }

    /// The order to build in: the session open on screen, then the patient
    /// being asked about, then newest first everywhere (the sessions most
    /// likely to be asked about).
    static func order(_ items: [Candidate], session: UUID?, patient: UUID?) -> [Candidate] {
        func rank(_ c: Candidate) -> Int {
            if c.sessionID == session { return 0 }
            if c.patientID == patient { return 1 }
            return 2
        }
        return items.sorted { l, r in
            let lr = rank(l), rr = rank(r)
            if lr != rr { return lr < rr }
            if l.date != r.date { return l.date > r.date }
            return l.sessionID.uuidString < r.sessionID.uuidString
        }
    }

    /// The one control beside the status.
    enum Action: Equatable {
        case pause, resume, prepareNow

        var title: String {
            switch self {
            case .pause: return "Pause"
            case .resume: return "Resume"
            case .prepareNow: return "Prepare now"
            }
        }
    }

    /// The calm status line for one patient, and its control. Nil when the
    /// patient needs no summaries (everything is read whole).
    static func status(
        ready: Int, needed: Int, pause: DigestPauseReason?, building: Bool
    ) -> (text: String, action: Action?)? {
        guard needed > 0 else { return nil }
        guard ready < needed else { return ("Summaries: all \(needed) ready", nil) }
        var text = "Summaries: \(ready) of \(needed) ready"
        let action: Action
        if let pause {
            text += " · " + pause.text
            if pause == .user {
                action = .resume
            } else if pause.canPrepareNow {
                action = .prepareNow
            } else {
                action = .pause
            }
        } else {
            if building { text += " · preparing" }
            action = .pause
        }
        return (text, action)
    }

    /// The key a section's summary is cached under: its text and everything
    /// that shapes its prompt, so a changed section, model or prompt is a miss
    /// and an unchanged one is reused after a stopped or failed build.
    static func sectionKey(text: String, anchor: String, model: String, promptVersion: Int) -> String {
        NoteFreshness.fingerprint(of: "\(promptVersion)\n\(model)\n\(anchor)\n\(text)")
    }
}
