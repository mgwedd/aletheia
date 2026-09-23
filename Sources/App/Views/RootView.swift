import AletheiaCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var updateService: UpdateService
    @EnvironmentObject private var encryption: EncryptionManager
    @ObservedObject private var navigator = AppNavigator.shared
    @State private var selectedPatient: Patient?
    @State private var showSettings = false
    @State private var showSearch = false

    var body: some View {
        NavigationSplitView {
            PatientsListView(selectedPatient: $selectedPatient)
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
                PatientDetailView(patient: selectedPatient)
                    .id(selectedPatient.id)
            } else {
                ContentUnavailableView(
                    "Select a Patient",
                    systemImage: "person.text.rectangle",
                    description: Text("Choose a patient on the left, or add a new one.")
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(appModel)
                .environmentObject(integrations)
                .environmentObject(updateService)
                .environmentObject(encryption)
                .frame(minWidth: 560, minHeight: 520)
        }
        .sheet(isPresented: $showSearch) {
            GlobalSearchView(onSelectPatient: { selectedPatient = $0 })
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
        .onChange(of: navigator.pendingPatientID) { _, _ in navigateToPendingPatient() }
        .onAppear { navigateToPendingPatient() }
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
