import Foundation

/// The system calls behind the setup checklist's permission and folder buttons.
@MainActor
protocol SetupSystem: AnyObject {
    func chooseFolder() -> URL?
    func requestMicrophone() async -> Bool
    func openMicrophoneSettings()
    func requestCallAudio() async -> Bool
    func callAudioGranted() -> Bool
    func openCallAudioSettings()
    func armCallAudioProbe()
    func confirmCallAudioGrant()
}

@MainActor
final class LiveSetupSystem: SetupSystem {
    func chooseFolder() -> URL? { FolderPicker.choose() }
    func requestMicrophone() async -> Bool { await MicRecorder.requestPermission() }
    func openMicrophoneSettings() { SystemSettingsLinks.openMicrophoneSettings() }
    func requestCallAudio() async -> Bool { await SystemAudioCapture.requestPermission() }
    // Non-prompting check only; the activation refresh runs the one live probe.
    func callAudioGranted() -> Bool { SystemAudioCapture.checkPermission() }
    func openCallAudioSettings() { SystemSettingsLinks.openScreenRecordingSettings() }
    func armCallAudioProbe() { ScreenAccessProbeGate.arm() }
    func confirmCallAudioGrant() { CallAudioGrantStore.standard.confirm() }
}

/// What the checklist's folder and permission buttons do. Returns true when it
/// handled the action; other actions are left to the caller.
@MainActor
struct SetupActionRunner {
    let system: SetupSystem
    let settings: AppSettings
    let rebuildStore: () -> Void
    /// How long to wait between looks for the grant (~30s in total by default).
    var pollInterval: TimeInterval = 0.5
    var maxPolls: Int = 60

    init(system: SetupSystem, settings: AppSettings, rebuildStore: @escaping () -> Void,
         pollInterval: TimeInterval = 0.5, maxPolls: Int = 60) {
        self.system = system
        self.settings = settings
        self.rebuildStore = rebuildStore
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
    }

    func perform(_ action: SetupAction) async throws -> Bool {
        switch action {
        case .chooseFolder:
            if let url = system.chooseFolder() {
                try settings.setDataRoot(url)
                rebuildStore()
            }
        case .requestMicrophone:
            _ = await system.requestMicrophone()
        case .openMicrophoneSettings:
            system.openMicrophoneSettings()
        case .requestScreenRecording:
            // One explicit system prompt. If macOS won't grant it there (or won't
            // prompt at all), send them to the pane and watch for the grant so the
            // row turns green with no relaunch.
            if await system.requestCallAudio() {
                system.confirmCallAudioGrant()
            } else {
                system.armCallAudioProbe()
                system.openCallAudioSettings()
                _ = await waitForCallAudioGrant()
            }
        case .openScreenRecordingSettings:
            system.armCallAudioProbe()
            system.openCallAudioSettings()
            _ = await waitForCallAudioGrant()
        default:
            return false
        }
        return true
    }

    /// Looks for the grant until it lands, then stops. Gives up quietly.
    func waitForCallAudioGrant() async -> Bool {
        for _ in 0..<maxPolls {
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if system.callAudioGranted() { return true }
        }
        return false
    }
}
