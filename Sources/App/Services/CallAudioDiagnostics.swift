import Foundation

/// A point-in-time picture of why call audio is or isn't being captured, for
/// the debug panel on the recording screen (`CallAudioDebugView`) and Doctor's
/// report. Permission and stream state only: no audio, names or paths.
struct CallAudioDiagnostics: Equatable {
    /// What the most recent Record did about call audio.
    enum StartResult: Equatable {
        case notTried
        case started
        /// `CallAudioStartPolicy` said not to try.
        case skipped
        case failed(String)

        var label: String {
            switch self {
            case .notTried: return "no recording yet this launch"
            case .started: return "started"
            case .skipped: return "skipped (access not confirmed, already tried this launch)"
            case .failed(let reason): return "failed: \(reason)"
            }
        }
    }

    var preflightGranted: Bool
    var currentBuild: String
    /// The build `CallAudioGrantStore` last confirmed access for, if any.
    var confirmedBuild: String?
    var attemptedThisLaunch: Bool
    var workedThisLaunch: Bool
    var lastStart: StartResult
    var streamRunning: Bool
    var streamDisrupted: Bool
    var buffersReceived: Int
    /// nil when no call recording is open.
    var bytesWritten: Int64?
    var disruptions: Int
    var firstFailure: String?

    /// Domain and code only: the code is what tells a denied grant from any
    /// other failure, and unlike the message it can't carry a file path.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    var hasProblem: Bool {
        switch lastStart {
        case .skipped, .failed: return true
        case .notTried, .started: return streamDisrupted || disruptions > 0
        }
    }

    var rows: [(label: String, value: String)] {
        [
            ("Preflight granted", preflightGranted ? "yes" : "no"),
            ("Build", currentBuild),
            ("Grant confirmed for", confirmedBuild ?? "none"),
            ("Attempted this launch", attemptedThisLaunch ? "yes" : "no"),
            ("Worked this launch", workedThisLaunch ? "yes" : "no"),
            ("Last start", lastStart.label),
            ("Stream", streamDisrupted ? "disrupted" : (streamRunning ? "running" : "not running")),
            ("Buffers received", String(buffersReceived)),
            ("Bytes written", bytesWritten.map(String.init) ?? "no file open"),
            ("Disruptions", String(disruptions)),
            ("First failure", firstFailure ?? "none")
        ]
    }

    /// One line for Doctor's report. Leaves out the first-failure message: it is
    /// free text from the system and could name a file.
    var summary: String {
        rows.dropLast().map { "\($0.label): \($0.value)" }.joined(separator: "; ")
    }
}
