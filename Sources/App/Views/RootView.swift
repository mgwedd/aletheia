import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var updateService: UpdateService
    @EnvironmentObject private var encryption: EncryptionManager
    @EnvironmentObject private var recorder: SessionRecorder
    @EnvironmentObject private var transcription: TranscriptionCoordinator
    @EnvironmentObject private var exports: ExportJobCenter
    @ObservedObject private var navigator = AppNavigator.shared
    @Environment(\.openWindow) private var openWindow
    @State private var selectedPatient: Patient?
    @State private var showSettings = false
    /// Bound so the sidebar can be brought back from the detail pane's title bar
    /// and from the search home (View > Show/Hide Sidebar is `SidebarCommands`).
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    /// The search field at the foot of the sidebar and its results (see `GlobalSearchField`).
    @StateObject private var search = GlobalSearchModel()
    @FocusState private var searchFocused: Bool
    /// The search home's large field, which ⌘F focuses while no patient is open.
    @FocusState private var homeSearchFocused: Bool
    /// The patient whose profile is being edited; the sheet is shared by the
    /// detail view's Edit button and the sidebar's context menu.
    @State private var editingProfile: Patient?
    @State private var editingFocus: ProfileField = .name

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PatientsListView(
                selectedPatient: $selectedPatient,
                search: search,
                searchFocused: $searchFocused,
                onOpenSearchResult: { openSearchResult($0) },
                onOpenSettings: { showSettings = true },
                onEditProfile: { editingFocus = .name; editingProfile = $0 }
            )
        } detail: {
            // Results cover the detail pane while there is a query, and the pane
            // stays underneath (so an open session keeps its unsaved edits).
            detailContent
                .accessibilityHidden(search.hasQuery && hasOpenPatient)
                .overlay {
                    // With no patient open the search home shows its own results.
                    if search.hasQuery && hasOpenPatient {
                        GlobalSearchResultsView(model: search, onOpen: { openSearchResult($0) })
                    }
                }
                // No toolbar items here on purpose: a wide one (the old 280pt search
                // field) pushed the system sidebar toggle into the » overflow menu,
                // leaving a collapsed sidebar with no way back.
        }
        .modifier(GlobalSearchRunning(
            search: search, appModel: appModel, isFocused: hasOpenPatient ? $searchFocused : $homeSearchFocused))
        // A records export keeps running while the therapist works; its progress and
        // the finished file are shown here whichever patient is open.
        .overlay(alignment: .bottomTrailing) {
            ExportStatusToast(center: exports).padding(16)
        }
        // Data-safety notices: an unopenable database (nothing can be saved) or a
        // single failed save. Non-blocking, but pinned above everything so it's
        // never missed. See DatabaseUnavailableBanner / DoctorFeatureModule.
        .safeAreaInset(edge: .top, spacing: 0) { dataSafetyNotices }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(appModel)
                .environmentObject(integrations)
                .environmentObject(updateService)
                .environmentObject(encryption)
        }
        .sheet(item: $editingProfile) { patient in
            PatientProfileEditor(
                patient: appModel.patients.first { $0.id == patient.id } ?? patient,
                showsMedications: appModel.featureRegistry.contains(id: PatientMedicationsFeatureModule.id),
                initialFocus: editingFocus
            )
            .environmentObject(appModel)
        }
        .sheet(isPresented: updatePresented) {
            if let release = updateService.available {
                UpdatePromptView(
                    release: release,
                    onUpdate: { updateService.installAvailableUpdate() },
                    onSkip: { updateService.skipAvailableVersion() },
                    onLater: { updateService.dismiss() }
                )
            }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appModel.errorMessage ?? "")
        }
        .alert("Update Aletheia", isPresented: schemaWarningBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appModel.schemaWarning ?? "")
        }
        .alert(
            updateService.manualNotice?.title ?? "",
            isPresented: manualNoticeBinding
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(updateService.manualNotice?.message ?? "")
        }
        // Here rather than on the session screen, so it appears whatever is on
        // screen and names the session that is actually recording.
        .alert("Still recording", isPresented: $recorder.longRunningReminder) {
            Button("Keep Recording", role: .cancel) {}
            Button("Stop Now", role: .destructive) { Task { await recorder.stop() } }
        } message: {
            Text(SessionNotifications.longRecordingReminder(
                patientName: recorder.active?.patientName ?? "This patient",
                showsName: true   // in-app alert behind the app lock, not a lock-screen banner
            ).body)
        }
        // `selectedPatient` is a snapshot; keep it in step with saves (matched by
        // id) so the detail view and sidebar selection never hold a stale copy.
        // The detail view's identity is keyed on the id alone, so this refresh
        // doesn't recreate it or drop in-progress edits.
        .onChange(of: appModel.patients) { _, patients in
            guard let current = selectedPatient else {
                selectedPatient = patients.first
                return
            }
            if let fresh = patients.first(where: { $0.id == current.id }) {
                if fresh != current {
                    selectedPatient = fresh
                }
            } else {
                selectedPatient = patients.first
            }
        }
        .onChange(of: navigator.pendingPatientID) { _, _ in navigateToPendingPatient() }
        .onAppear { navigateToPendingPatient() }
        .modifier(SearchActivityReporting(
            appModel: appModel, recorder: recorder, transcription: transcription, inferenceQueue: integrations.inferenceQueue))
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selectedPatient, appModel.patients.contains(where: { $0.id == selectedPatient.id }) {
            PatientDetailView(patient: selectedPatient, onEditProfile: { field in editingFocus = field; editingProfile = selectedPatient })
                .id(selectedPatient.id)
                .background(Theme.window.color)
        } else {
            SearchHomeView(
                model: search, onOpen: { openSearchResult($0) }, isFocused: $homeSearchFocused,
                sidebarHidden: columnVisibility == .detailOnly, onShowSidebar: { columnVisibility = .all }
            )
        }
    }

    private var hasOpenPatient: Bool {
        if let selectedPatient { return appModel.patients.contains { $0.id == selectedPatient.id } }
        return false
    }

    /// Opens a search result: selects the patient and, for anything inside a
    /// session, opens that session where the match is. Then the search clears.
    private func openSearchResult(_ hit: SearchHit) {
        let destination = SearchHitDestination(hit)
        selectedPatient = hit.patient
        if let sessionID = destination.sessionID {
            navigator.requestOpenSession(
                patientID: destination.patientID,
                sessionID: sessionID,
                initialTab: destination.tab,
                initialNoteFormat: destination.noteFormat,
                initialShowingMyNotes: destination.showingMyNotes,
                initialFocusedCommentID: destination.commentID,
                initialSearchFocus: destination.searchFocus(query: search.query)
            )
        }
        search.clear()
        searchFocused = false
    }

    private var doctorAvailable: Bool {
        appModel.featureRegistry.contains(id: DoctorFeatureModule.id)
    }

    @ViewBuilder
    private var dataSafetyNotices: some View {
        VStack(spacing: 0) {
            if let failure = appModel.databaseState.failure {
                DatabaseUnavailableBanner(
                    failure: failure,
                    dataFolder: settings.dataRootURL,
                    showDoctorButton: doctorAvailable,
                    onOpenDoctor: { openWindow(id: DoctorFeatureModule.windowID) },
                    onTryAgain: { appModel.reopenDatabase() },
                    onChooseFolder: { appModel.chooseDataFolder() }
                )
            } else if let subject = appModel.saveFailureSubject {
                // Only when the database itself is open: an unopenable database is
                // already covered by the banner above.
                SaveFailureStrip(
                    subject: subject,
                    showDoctorButton: doctorAvailable,
                    onOpenDoctor: { openWindow(id: DoctorFeatureModule.windowID) },
                    onDismiss: { appModel.dismissSaveFailure() }
                )
            }
        }
    }

    /// Honors a navigation request from an App Intent (Siri/Shortcuts).
    private func navigateToPendingPatient() {
        guard let id = navigator.pendingPatientID else { return }
        appModel.refreshPatients()
        if let match = appModel.patients.first(where: { $0.id == id }) {
            selectedPatient = match
        }
        navigator.pendingPatientID = nil
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { appModel.errorMessage != nil },
            set: { if !$0 { appModel.errorMessage = nil } }
        )
    }

    private var updatePresented: Binding<Bool> {
        Binding(
            get: { updateService.available != nil },
            set: { if !$0 { updateService.dismiss() } }
        )
    }

    private var schemaWarningBinding: Binding<Bool> {
        Binding(
            get: { appModel.schemaWarning != nil },
            set: { if !$0 { appModel.schemaWarning = nil } }
        )
    }

    private var manualNoticeBinding: Binding<Bool> {
        Binding(
            get: { updateService.manualNotice != nil },
            set: { if !$0 { updateService.clearManualNotice() } }
        )
    }
}

/// Tells the background search-index sweep when to wait: while recording,
/// transcribing, or while the AI model is generating.
private struct SearchActivityReporting: ViewModifier {
    let appModel: AppModel
    @ObservedObject var recorder: SessionRecorder
    @ObservedObject var transcription: TranscriptionCoordinator
    @ObservedObject var inferenceQueue: InferenceQueue

    func body(content: Content) -> some View {
        content
            .onChange(of: recorder.isRecording, initial: true) { _, on in
                appModel.searchActivity.set(.recording, active: on)
            }
            .onChange(of: transcription.isBusy, initial: true) { _, on in
                appModel.searchActivity.set(.transcription, active: on)
            }
            .onChange(of: inferenceQueue.running != nil, initial: true) { _, on in
                appModel.searchActivity.set(.model, active: on)
            }
    }
}

/// Runs the global search whenever its query, its limits or the index change
/// (each run cancels the one before), and binds ⌘F for the window.
private struct GlobalSearchRunning: ViewModifier {
    @ObservedObject var search: GlobalSearchModel
    let appModel: AppModel
    var isFocused: FocusState<Bool>.Binding
    @State private var indexRevision = 0

    private struct Run: Equatable {
        let query: String
        let limits: GlobalSearchLimits
        let revision: Int
    }

    func body(content: Content) -> some View {
        content
            .background { GlobalSearchHotkey(isFocused: isFocused) }
            .task(id: Run(query: search.query, limits: search.limits, revision: indexRevision)) {
                await search.run(store: appModel.store)
            }
            .onReceive(appModel.searchIndexMonitor.$revision) { indexRevision = $0 }
    }
}
