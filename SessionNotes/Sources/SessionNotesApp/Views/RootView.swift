import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedPatient: Patient?
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            PatientsListView(selectedPatient: $selectedPatient)
                .toolbar {
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
                .frame(minWidth: 560, minHeight: 520)
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
}
