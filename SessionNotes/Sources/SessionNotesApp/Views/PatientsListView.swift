import SwiftUI

struct PatientsListView: View {
    @EnvironmentObject private var appModel: AppModel
    @Binding var selectedPatient: Patient?

    @State private var searchText = ""
    @State private var showAddPatient = false
    @State private var newPatientName = ""

    private var filteredPatients: [Patient] {
        guard !searchText.isEmpty else { return appModel.patients }
        return appModel.patients.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List(filteredPatients, selection: $selectedPatient) { patient in
            Text(patient.name)
                .font(.headline)
                .padding(.vertical, 2)
                .tag(patient)
        }
        .searchable(text: $searchText, prompt: "Search patients")
        .navigationTitle("Patients")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newPatientName = ""
                    showAddPatient = true
                } label: {
                    Label("Add Patient", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddPatient) {
            AddPatientSheet(name: $newPatientName) {
                if let created = appModel.addPatient(name: newPatientName) {
                    selectedPatient = created
                }
                showAddPatient = false
            } onCancel: {
                showAddPatient = false
            }
        }
        .onAppear { appModel.refreshPatients() }
    }
}

private struct AddPatientSheet: View {
    @Binding var name: String
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Patient").font(.title2.bold())
            TextField("Patient name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onAdd)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Add", action: onAdd)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
