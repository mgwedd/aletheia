import Foundation

/// What the menu-bar icon and panel show, decided in one place so the views
/// and the tests read the same strings.
enum MenuBarPanel {
    /// The icon: a filled red dot while recording, paused while paused, and a
    /// neutral waveform when idle.
    static func iconSymbol(isRecording: Bool, isPaused: Bool) -> String {
        guard isRecording else { return "waveform" }
        return isPaused ? "pause.circle.fill" : "record.circle.fill"
    }

    enum Strings {
        static let locked = "Aletheia is locked"
        static let unlock = "Unlock"
        static let notRecording = "Not recording"
        static let patientPicker = "Patient"
        static let startRecording = "Start recording"
        static let recordingChip = "Recording"
        static let pausedChip = "Paused"
        static let pause = "Pause"
        static let resume = "Resume"
        static let stopAndSave = "Stop and save"
        static let noPatients = "Add a patient in the main window first."
    }

    enum State: Equatable {
        case locked, recording, paused, idle
    }

    static func state(isLocked: Bool, isRecording: Bool, isPaused: Bool) -> State {
        if isLocked { return .locked }
        guard isRecording else { return .idle }
        return isPaused ? .paused : .recording
    }

    /// What the panel offers in a state: the status line, the controls by
    /// title, and whether it shows anything about the patient or the session.
    struct Content: Equatable {
        let status: String?
        let controls: [String]
        let showsSessionDetail: Bool
    }

    static func content(_ state: State, hasPatients: Bool) -> Content {
        switch state {
        case .locked:
            return Content(status: Strings.locked, controls: [Strings.unlock], showsSessionDetail: false)
        case .idle:
            return hasPatients
                ? Content(status: Strings.notRecording, controls: [Strings.patientPicker, Strings.startRecording], showsSessionDetail: false)
                : Content(status: Strings.notRecording, controls: [], showsSessionDetail: false)
        case .recording:
            return Content(status: Strings.recordingChip, controls: [Strings.pause, Strings.stopAndSave], showsSessionDetail: true)
        case .paused:
            return Content(status: Strings.pausedChip, controls: [Strings.resume, Strings.stopAndSave], showsSessionDetail: true)
        }
    }
}
