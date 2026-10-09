import SwiftUI

struct PatientsListView: View {
    @EnvironmentObject private var appModel: AppModel
    @Binding var selectedPatient: Patient?
    let onEditProfile: (Patient) -> Void

    @State private var searchText = ""
    @State private var showAddPatient = false
    @State private var newPatientName = ""

    private var filteredPatients: [Patient] {
        guard !searchText.isEmpty else { return appModel.patients }
        return appModel.patients.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Patients")
                .eyebrowStyle()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

            List(filteredPatients, selection: $selectedPatient) { patient in
                PatientRow(patient: patient, isSelected: selectedPatient?.id == patient.id)
                    .tag(patient)
                    .contextMenu {
                        Button("Edit Profile…") { onEditProfile(patient) }
                    }
            }
            .listStyle(.plain)
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
                        .buttonStyle(.themePrimary)
                    }
                } else if filteredPatients.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(Theme.sidebar.color)
        .searchable(text: $searchText, prompt: "Search patients")
        .navigationTitle("Patients")
        // An always-visible footer at the foot of the sidebar. The toolbar "+"
        // alone gets swept into the window's ">>" overflow when the pane is
        // narrow, so adding a patient looked impossible — this never hides.
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !appModel.unreadablePatients.isEmpty {
                DamagedRecordsNotice(
                    title: appModel.unreadablePatients.count == 1
                        ? "1 patient couldn't be read"
                        : "\(appModel.unreadablePatients.count) patients couldn't be read",
                    entries: appModel.unreadablePatients
                )
            }

            Button {
                newPatientName = ""
                showAddPatient = true
            } label: {
                Label("New patient", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.themed)
            .keyboardShortcut("n", modifiers: .command)
            .help("Add a new patient (⌘N)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar.color)
        .themeDivider(.top)
    }
}

/// One patient in the sidebar: a monogram avatar, the name, and when they were
/// added. Everything comes from the `Patient` already in memory; nothing here
/// reads from disk.
private struct PatientRow: View {
    let patient: Patient
    let isSelected: Bool

    private static let addedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            Text(PatientInitials.from(patient.name))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.chipInk.color)
                .frame(width: 30, height: 30)
                .background(Theme.chip.color, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(patient.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                Text("Added \(Self.addedFormatter.string(from: patient.createdAt))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .themeListRow(isSelected: isSelected, surface: Theme.sidebar)
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
                    .buttonStyle(.themed)
                Button("Add", action: onAdd)
                    .buttonStyle(.themePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 360)
    }
}
