import SwiftUI
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

@main
struct AletheiaApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var appModel: AppModel
    @StateObject private var integrations: Integrations
    @StateObject private var updateService: UpdateService
    @StateObject private var appLock: AppLock
    /// Tier-2 at-rest encryption: owns the folder's key lifecycle and hands the
    /// stores a `FileProtector`. Off until the user turns it on in Settings.
    @StateObject private var encryption: EncryptionManager
    /// One recorder for the whole app, shared by the session view and the
    /// menu-bar control so both drive (and reflect) the same recording.
    @StateObject private var recorder = SessionRecorder()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = AppSettings.shared
        _settings = StateObject(wrappedValue: settings)
        let encryption = EncryptionManager(dataRootProvider: { settings.dataRootURL })
        _encryption = StateObject(wrappedValue: encryption)
        let appModel = AppModel(settings: settings, encryption: encryption)
        _appModel = StateObject(wrappedValue: appModel)
        _integrations = StateObject(wrappedValue: Integrations(settings: settings))
        _updateService = StateObject(wrappedValue: UpdateService(
            checker: AppcastUpdateChecker(feedURL: settings.updateFeedURL),
            currentVersion: UpdateService.bundleVersion()
        ))
        let appLock = AppLock(settings: settings)
        // Record each successful unlock in the on-device audit log (HIPAA
        // §164.312(b)). AppLock stays decoupled from the log via this hook.
        appLock.onUnlock = { [weak appModel] in appModel?.recordAudit(.appUnlocked) }
        _appLock = StateObject(wrappedValue: appLock)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(appModel)
                .environmentObject(integrations)
                .environmentObject(updateService)
                .environmentObject(recorder)
                .environmentObject(encryption)
                .sheet(isPresented: showFirstRun) {
                    FirstRunView()
                        .environmentObject(settings)
                        .environmentObject(appModel)
                        .environmentObject(integrations)
                }
                .frame(minWidth: 900, minHeight: 600)
                .task { await updateService.checkForUpdates() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await updateService.checkForUpdates() }
                    case .background:
                        // Re-lock when the app is hidden, so stepping away
                        // re-requires Touch ID / password to see PHI again.
                        appLock.lockIfEnabled()
                    default:
                        break
                    }
                }
                .modifier(SpotlightContinuationModifier())
                // Tier-1 protection: cover everything until the user authenticates.
                .overlay {
                    if appLock.isLocked {
                        LockView()
                            .environmentObject(appLock)
                            .transition(.opacity)
                    }
                }
                // Tier-2: an encrypted folder needs its passphrase once per launch
                // before its notes can be read or written.
                .overlay {
                    if settings.dataRootURL != nil && encryption.state == .lockedNeedsPassphrase {
                        EncryptionUnlockView()
                            .environmentObject(encryption)
                            .environmentObject(settings)
                            .environmentObject(appModel)
                            .transition(.opacity)
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Put a real "Check for Updates…" in the app menu, next to About,
            // so updates aren't only a silent on-launch check.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updateService.checkForUpdates() }
                }
            }
        }

        // Gives the standard "Settings…" (⌘,) item in the app menu — the macOS
        // home every Mac user reaches for — backed by the same AppSettings the
        // in-window Settings sheet uses.
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(appModel)
                .environmentObject(integrations)
                .environmentObject(updateService)
                .environmentObject(encryption)
                .frame(minWidth: 520, minHeight: 480)
        }

        MenuBarExtra("Aletheia Recording", systemImage: menuBarSymbol) {
            RecordingMenuBar()
                .environmentObject(recorder)
                .environmentObject(appModel)
                .environmentObject(settings)
                .environmentObject(integrations)
        }
        .menuBarExtraStyle(.window)
    }

    /// The menu-bar icon reflects recording state at a glance: a filled red dot
    /// while recording, paused while paused, and a neutral waveform when idle.
    private var menuBarSymbol: String {
        guard recorder.isRecording else { return "waveform" }
        return recorder.isPaused ? "pause.circle.fill" : "record.circle.fill"
    }

    private var showFirstRun: Binding<Bool> {
        Binding(
            // The sheet can't be dismissed by the user (set is a no-op), so the
            // app is unusable until the data folder is chosen, first run is
            // done, AND the current Terms/Privacy version has been accepted —
            // re-appearing if the terms version changes.
            get: {
                settings.dataRootURL == nil
                    || !settings.hasCompletedFirstRun
                    || !settings.hasAcceptedCurrentLegal
            },
            set: { _ in }
        )
    }
}
