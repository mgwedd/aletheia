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
    }

    private var showFirstRun: Binding<Bool> {
        Binding(
            get: { settings.dataRootURL == nil || !settings.hasCompletedFirstRun },
            set: { _ in }
        )
    }
}
