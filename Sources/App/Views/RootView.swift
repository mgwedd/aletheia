import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var updateService: UpdateService
    @EnvironmentObject private var encryption: EncryptionManager
    @EnvironmentObject private var recorder: SessionRecorder
    @EnvironmentObject private var transcription: TranscriptionCoordinator
    @ObservedObject private var navigator = AppNavigator.shared
    @Environment(\.openWindow) private var openWindow
    @State private var selectedPatient: Patient?
    @State private var showSettings = false
    @State private var showSearch = false
    /// The patient whose profile is being edited; the sheet is shared by the
    /// detail view's Edit button and the sidebar's context menu.
    @State private var editingProfile: Patient?
    @State private var editingFocus: ProfileField = .name

    var body: some View {
        NavigationSplitView {
            PatientsListView(selectedPatient: $selectedPatient, onEditProfile: { editingFocus = .name; editingProfile = $0 })
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showSearch = true
                        } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
        } detail: {
            if let selectedPatient, appModel.patients.contains(where: { $0.id == selectedPatient.id }) {
                PatientDetailView(patient: selectedPatient, onEditProfile: { field in editingFocus = field; editingProfile = selectedPatient })
                    .id(selectedPatient.id)
                    .background(Theme.window.color)
            } else {
                ContentUnavailableView(
                    "Select a Patient",
                    systemImage: "person.text.rectangle",
                    description: Text("Choose a patient on the left, or add a new one.")
                )
                .background(Theme.window.color)
            }
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
        .sheet(isPresented: $showSearch) {
            GlobalSearchView(onOpen: { hit in
                selectedPatient = hit.patient
                if let session = hit.session {
                    let initialTab: SessionTab
                    var noteFormat: ProgressNoteFormat?
                    var showingMyNotes = false
                    var commentID: String?

                    switch hit.kind {
                    case .note:
                        initialTab = .notes
                        noteFormat = hit.noteFormat
                        showingMyNotes = false
                    case .sessionNotes:
                        initialTab = .notes
                        showingMyNotes = true
                    case .comment:
                        initialTab = .transcript
                        commentID = hit.commentID
                    case .transcript, .session, .patient:
                        initialTab = .transcript
                    }

                    navigator.requestOpenSession(
                        patientID: hit.patient.id,
                        sessionID: session.id,
                        initialTab: initialTab,
                        initialNoteFormat: noteFormat,
                        initialShowingMyNotes: showingMyNotes,
                        initialFocusedCommentID: commentID
                    )
                }
            })
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
