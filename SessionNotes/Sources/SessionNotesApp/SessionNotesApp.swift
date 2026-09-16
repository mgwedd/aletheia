import SwiftUI

@main
struct SessionNotesApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var appModel: AppModel
    @StateObject private var integrations: Integrations

    init() {
        let settings = AppSettings.shared
        _settings = StateObject(wrappedValue: settings)
        _appModel = StateObject(wrappedValue: AppModel(settings: settings))
        _integrations = StateObject(wrappedValue: Integrations(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(appModel)
                .environmentObject(integrations)
                .sheet(isPresented: showFirstRun) {
                    FirstRunView()
                        .environmentObject(settings)
                        .environmentObject(appModel)
                }
                .frame(minWidth: 900, minHeight: 600)
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
