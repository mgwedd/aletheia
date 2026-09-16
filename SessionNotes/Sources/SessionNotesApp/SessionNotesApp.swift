import SwiftUI

@main
struct SessionNotesApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var appModel: AppModel
    @StateObject private var integrations: Integrations
    @StateObject private var updateService: UpdateService
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
                }
                .frame(minWidth: 900, minHeight: 600)
                .task { await updateService.checkForUpdates() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await updateService.checkForUpdates() }
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
