import SwiftUI
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

@main
struct SessionNotesApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var appModel: AppModel
    @StateObject private var integrations: Integrations
    @StateObject private var updateService: UpdateService
    @StateObject private var appLock: AppLock
    /// One recorder for the whole app, shared by the session view and the
    /// menu-bar control so both drive (and reflect) the same recording.
    @StateObject private var recorder = SessionRecorder()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = AppSettings.shared
        _settings = StateObject(wrappedValue: settings)
        _appModel = StateObject(wrappedValue: AppModel(settings: settings))
        _integrations = StateObject(wrappedValue: Integrations(settings: settings))
        _updateService = StateObject(wrappedValue: UpdateService(
            checker: AppcastUpdateChecker(feedURL: settings.updateFeedURL),
            currentVersion: UpdateService.bundleVersion()
        ))
        _appLock = StateObject(wrappedValue: AppLock(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(appModel)
                .environmentObject(integrations)
                .environmentObject(updateService)
                .environmentObject(recorder)
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
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("Aletheia Recording", systemImage: menuBarSymbol) {
            RecordingMenuBar()
                .environmentObject(recorder)
                .environmentObject(appModel)
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
