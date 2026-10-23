import SwiftUI
import AppKit
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

private extension View {
    /// Applies `SpotlightContinuationModifier` only when the build ships the
    /// Spotlight feature module — a build without it must not route a stray
    /// Spotlight continuation into the app.
    @ViewBuilder
    func spotlightContinuation(enabled: Bool) -> some View {
        if enabled {
            modifier(SpotlightContinuationModifier())
        } else {
            self
        }
    }
}

/// Launch-time setup that has to happen before the first window exists.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // A test run launches this app as its host: keep it from taking focus.
        if let policy = TestHost.activationPolicy() { NSApp.setActivationPolicy(policy) }
        // Before any window is created, so a forced Light or Dark appearance
        // never flashes the system one first.
        AppSettings.shared.appearance.apply()
        HelpTipsStore.configure()
    }

    /// Quitting (⌘Q, the menu-bar Quit, logout or restart) waits for the
    /// running work to wind down, but never longer than the shutdown deadline,
    /// and never with an alert: interrupted work is saved for the next launch.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown = AppLifecycle.shutdown else { return .terminateNow }
        // Already winding down: the reply below ends this quit too.
        guard !shutdown.isShuttingDown else { return .terminateLater }
        Task { @MainActor in
            await shutdown.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        TestHost.concealWindowsWhenHostingTests()
        #if DEBUG
        HarnessRun.runIfRequested()
        #endif
    }
}

@main
struct AletheiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
    @StateObject private var recorder: SessionRecorder
    /// App-level transcription runner, so progress survives leaving the session
    /// screen and shows in the sidebar and menu bar.
    @StateObject private var transcription: TranscriptionCoordinator
    /// Patient-records exports run in the background and report through this.
    @StateObject private var exports: ExportJobCenter
    /// Keeps every app window out of screen sharing per the setting, and hides
    /// sheets, alerts and popovers while the app is locked.
    private let windowShield: WindowShield
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    init() {
        let settings = AppSettings.shared
        _settings = StateObject(wrappedValue: settings)
        let encryption = EncryptionManager(dataRootProvider: { settings.dataRootURL })
        _encryption = StateObject(wrappedValue: encryption)
        let appLock = AppLock(settings: settings)
        if appLock.isLocked { encryption.lock() }
        SessionSearch.setAppLocked(appLock.isLocked)   // before AppModel builds the index: it starts closed behind the lock
        let appModel = AppModel(settings: settings, encryption: encryption)
        _appModel = StateObject(wrappedValue: appModel)
        let integrations = Integrations(settings: settings)
        _integrations = StateObject(wrappedValue: integrations)
        let transcription = TranscriptionCoordinator(
            appModel: appModel,
            integrations: integrations,
            settings: settings
        )
        _transcription = StateObject(wrappedValue: transcription)
        let recorder = SessionRecorder()
        recorder.onStopped = { [weak transcription] in transcription?.startAfterRecording($0) }
        // Also a system notification, so it's noticed when the app isn't
        // focused (the therapist has likely switched to the call window).
        recorder.onLongRunning = { [weak integrations] recording in
            Task {
                await integrations?.makeNotifier().post(
                    SessionNotifications.longRecordingReminder(
                        patientName: recording.patientName,
                        showsName: settings.notificationsShowPatientNames
                    )
                )
            }
        }
        _recorder = StateObject(wrappedValue: recorder)
        let exports = ExportJobCenter(notifier: UserNotificationService())
        _exports = StateObject(wrappedValue: exports)
        ReturnKeyActivation.install()
        AppLifecycle.configure(
            settings: settings, appModel: appModel, recorder: recorder,
            transcription: transcription, integrations: integrations, exports: exports)
        _updateService = StateObject(wrappedValue: UpdateService(
            checker: AppcastUpdateChecker(),
            currentVersion: UpdateService.bundleVersion()
        ))
        // Record each successful unlock in the on-device audit log (HIPAA
        // §164.312(b)). AppLock stays decoupled from the log via this hook.
        appLock.onUnlock = { [weak appModel, weak encryption] in
            encryption?.autoUnlockFromDevice()
            appModel?.recordAudit(.appUnlocked)
            appModel?.reindexSpotlight()
        }
        appLock.onLock = { [weak encryption] in encryption?.lock() }
        // A recording or transcription keeps the key it started with until it
        // ends; dropping it mid-way would leave the audio unsealed.
        appLock.observeBackgroundWork(
            busy: { [weak recorder, weak transcription] in
                (recorder.map { $0.isBusy || $0.hasOpenRecording } ?? false) || (transcription?.isBusy ?? false)
            },
            changes: recorder.objectWillChange.merge(with: transcription.objectWillChange).eraseToAnyPublisher()
        )
        let windowShield = WindowShield(appLock: appLock, settings: settings)
        windowShield.start()
        self.windowShield = windowShield
        appLock.onUnlockFailed = { [weak appModel] reason in
            appModel?.recordAudit(.appUnlockFailed, detail: reason)
        }
        appLock.onLocked = { [weak appModel] in
            appModel?.recordAudit(.appLocked)
        }
        _appLock = StateObject(wrappedValue: appLock)

        // Background summaries: only when nothing else is using the model, no
        // recording or transcription is running and the app is unlocked.
        integrations.digestScheduler.attach(
            context: { [weak appModel, weak integrations] in
                guard let appModel, let integrations, let store = appModel.store else { return nil }
                return DigestScheduler.Context(
                    store: store, patients: appModel.patients, service: integrations.makeAssistantService())
            },
            activity: { [weak recorder, weak transcription, weak appLock] in
                DigestActivity(
                    locked: appLock?.isLocked ?? true,
                    recording: recorder?.isBusy ?? false,
                    transcribing: transcription?.isBusy ?? false,
                    lowPowerMode: PowerSource.isLowPowerMode,
                    onBattery: PowerSource.isOnBattery
                )
            }
        )
    }

    var body: some Scene {
        WindowGroup(id: MainWindow.id) {
            RootView()
                .noWritingTools()
                .background(MainWindowCapture())
                .environmentObject(settings)
                .environmentObject(appModel)
                .environmentObject(integrations)
                .environmentObject(updateService)
                .environmentObject(recorder)
                .environmentObject(transcription)
                .environmentObject(encryption)
                .environmentObject(exports)
                .sheet(isPresented: showFirstRun) {
                    FirstRunView()
                        .noWritingTools()
                        .environmentObject(settings)
                        .environmentObject(appModel)
                        .environmentObject(integrations)
                        // A sheet gets a fresh environment on macOS, so the
                        // objects FirstRunView (and the encryption setup sheet it
                        // presents) reads must be injected here explicitly.
                        .environmentObject(encryption)
                }
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    if settings.autoCheckForUpdates {
                        await updateService.checkForUpdates()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // AppLock observes hide (when enabled), idle, sleep and screen lock.
                    if phase == .active, settings.autoCheckForUpdates {
                        Task { await updateService.checkForUpdates() }
                    }
                }
                .spotlightContinuation(enabled: appModel.featureRegistry.contains(id: SpotlightFeatureModule.id))
                .modifier(LockCover(appLock: appLock, encryption: encryption, settings: settings, appModel: appModel))
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            // View > Show/Hide Sidebar (⌃⌘S).
            SidebarCommands()
            // Stock File > Close Window (⌘W). Stated explicitly so it's always
            // present and works for the main, Doctor and Settings windows alike.
            CommandGroup(replacing: .saveItem) {
                Button("Close Window") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut(AppHotkey.closeWindow)
            }
            // Put a real "Check for Updates…" in the app menu, next to About,
            // so updates aren't only a silent on-launch check.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updateService.checkForUpdates(force: true) }
                }
            }
            // "Aletheia Doctor…" in the Help menu: the on-demand health check
            // (see DoctorFeatureModule). Also reachable from Settings and from the
            // database-unavailable banner.
            CommandGroup(after: .help) {
                Button("Keyboard Shortcuts") {
                    openWindow(id: ShortcutsWindow.id)
                }
                .keyboardShortcut(AppHotkey.showShortcuts)
                if appModel.featureRegistry.contains(id: DoctorFeatureModule.id) {
                    Button("Aletheia Doctor…") {
                        openWindow(id: DoctorFeatureModule.windowID)
                    }
                }
                Divider()
                // The feedback form on astrealabs.com, in the browser.
                Button("Report a Bug…") { NSWorkspace.shared.open(FeedbackLink.url(.bug)) }
                Button("Request a Feature…") { NSWorkspace.shared.open(FeedbackLink.url(.feature)) }
            }
        }

        // The patient-wide chat. A window, not a sheet, so it resizes, goes full
        // screen and closes with ⌘W. It carries the same lock covers as the main
        // window, since it shows patient data.
        WindowGroup("Ask About This Patient", id: PatientChatWindow.windowID, for: UUID.self) { $patientID in
            PatientChatWindow(patientID: patientID)
                .noWritingTools()
                .environmentObject(settings)
                .environmentObject(appModel)
                .environmentObject(integrations)
                .environmentObject(recorder)
                .modifier(LockCover(appLock: appLock, encryption: encryption, settings: settings, appModel: appModel))
        }
        .defaultSize(width: 920, height: 720)

        // The Doctor window (production tier). A separate window, not a sheet, so
        // it stays reachable when the main window is busy or showing an error.
        Window("Aletheia Doctor", id: DoctorFeatureModule.windowID) {
            DoctorView()
                .noWritingTools()
                .environmentObject(settings)
                .environmentObject(updateService)
                .environmentObject(recorder)
                .environmentObject(appModel)
                .environmentObject(integrations)
                .environmentObject(encryption)
                .modifier(LockCover(appLock: appLock, encryption: encryption, settings: settings, appModel: appModel))
        }
        .defaultSize(width: 620, height: 640)

        // The Keyboard Shortcuts window lists keys only, but follows the same
        // lock presentation as every other app window.
        Window("Keyboard Shortcuts", id: ShortcutsWindow.id) {
            ShortcutsView()
                .noWritingTools()
                .modifier(LockCover(appLock: appLock, encryption: encryption, settings: settings, appModel: appModel))
        }
        .defaultSize(width: 460, height: 560)

        // Gives the standard "Settings…" (⌘,) item in the app menu — the macOS
        // home every Mac user reaches for — backed by the same AppSettings the
        // in-window Settings sheet uses.
        Settings {
            SettingsView()
                .noWritingTools()
                .environmentObject(settings)
                .environmentObject(appModel)
                .environmentObject(integrations)
                .environmentObject(updateService)
                .environmentObject(encryption)
                .environmentObject(exports)
                .modifier(LockCover(appLock: appLock, encryption: encryption, settings: settings, appModel: appModel))
        }

        MenuBarExtra("Aletheia Recording", systemImage: menuBarSymbol) {
            RecordingMenuBar()
                .noWritingTools()
                .environmentObject(recorder)
                .environmentObject(transcription)
                .environmentObject(appModel)
                .environmentObject(settings)
                .environmentObject(integrations)
                .environmentObject(appLock)
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

/// Covers a window's content until the user is allowed to see patient data:
/// the app lock (Touch ID / password), then the passphrase for an encrypted
/// folder. Applied to every window that shows patient data.
private struct LockCover: ViewModifier {
    @ObservedObject var appLock: AppLock
    @ObservedObject var encryption: EncryptionManager
    @ObservedObject var settings: AppSettings
    @ObservedObject var appModel: AppModel

    func body(content: Content) -> some View {
        let covers = LockCoverPolicy.cover(
            appLocked: appLock.isLocked,
            hasDataFolder: settings.dataRootURL != nil,
            encryption: encryption.state
        )
        return content
            // Tier-2: an encrypted folder needs its passphrase once per launch
            // before its notes can be read or written. Added first so Tier-1
            // (added last) draws above it when both covers apply.
            .overlay {
                if covers.contains(.passphrase) {
                    FolderUnlockView()
                        .environmentObject(encryption)
                        .environmentObject(settings)
                        .environmentObject(appModel)
                        .transition(.opacity)
                }
                if covers.contains(.keystoreMissing) {
                    EncryptionKeystoreMissingView()
                        .environmentObject(encryption)
                        .environmentObject(settings)
                        .environmentObject(appModel)
                        .transition(.opacity)
                }
            }
            // Tier-1 protection: applied last so LockView always sits on top of
            // everything, including the passphrase sheet.
            .overlay {
                if covers.contains(.appLock) {
                    LockView()
                        .environmentObject(appLock)
                        .environmentObject(settings)
                        .transition(.opacity)
                }
            }
    }
}
