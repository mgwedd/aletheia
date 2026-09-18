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
                .padding(.vertical, 4)
                .tag(patient)
        }
        .overlay {
            if appModel.patients.isEmpty {
                ContentUnavailableView {
                    Label("No Patients Yet", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Add your first patient to start recording and reviewing sessions.")
                } actions: {
                    Button("Add Patient") {
                        newPatientName = ""
                        showAddPatient = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if filteredPatients.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: "Search patients")
        .navigationTitle("Patients")
        // An always-visible bar at the foot of the sidebar. The toolbar "+"
        // alone gets swept into the window's ">>" overflow when the pane is
        // narrow, so adding a patient looked impossible — this never hides.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    newPatientName = ""
                    showAddPatient = true
                } label: {
                    Label("New Patient", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .keyboardShortcut("n", modifiers: .command)
                .help("Add a new patient (⌘N)")
            }
            .background(.bar)
        }
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
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 360)
    }
}
