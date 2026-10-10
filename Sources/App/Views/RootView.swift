import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var updateService: UpdateService
    @EnvironmentObject private var encryption: EncryptionManager
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
                .frame(minWidth: 560, minHeight: 520)
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
            GlobalSearchView(onOpen: { patient, session in
                selectedPatient = patient
                if let session {
                    navigator.requestOpenSession(patientID: patient.id, sessionID: session.id)
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
        // `selectedPatient` is a snapshot; keep it in step with saves (matched by
        // id) so the detail view and sidebar selection never hold a stale copy.
        // The detail view's identity is keyed on the id alone, so this refresh
        // doesn't recreate it or drop in-progress edits.
        .onChange(of: appModel.patients) { _, patients in
            guard let current = selectedPatient,
                  let fresh = patients.first(where: { $0.id == current.id }),
                  fresh != current else { return }
            selectedPatient = fresh
        }
        .onChange(of: navigator.pendingPatientID) { _, _ in navigateToPendingPatient() }
        .onAppear { navigateToPendingPatient() }
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
                    onOpenDoctor: { openWindow(id: DoctorFeatureModule.windowID) }
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
}
