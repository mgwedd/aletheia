import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var integrations: Integrations
    @EnvironmentObject private var updateService: UpdateService
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
}
