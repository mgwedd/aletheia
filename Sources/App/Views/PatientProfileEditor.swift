import SwiftUI

/// Sheet for editing a patient's name, clinical history, medications and notes.
/// Nothing is written until Save; Cancel with unsaved changes asks first. The
/// whole profile is saved in one `updatePatient` call.
struct PatientProfileEditor: View {
    private let patientID: UUID
    private let original: Patient
    private let showsMedications: Bool

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var clinicalHistory: String
    @State private var notes: String
    @State private var medications: [Medication]
    @State private var confirmDiscard = false

    init(patient: Patient, showsMedications: Bool) {
        patientID = patient.id
        original = patient
        self.showsMedications = showsMedications
        _name = State(initialValue: patient.name)
        _clinicalHistory = State(initialValue: patient.clinicalHistory)
        _notes = State(initialValue: patient.notes)
        _medications = State(initialValue: patient.medications)
    }

    private var cleanedName: String? { Patient.normalizedName(name) }

    private var cleanedMedications: [Medication] {
        medications.filter { !($0.name.trimmingCharacters(in: .whitespaces).isEmpty
            && $0.dose.trimmingCharacters(in: .whitespaces).isEmpty) }
    }

    private var hasChanges: Bool {
        if let cleanedName, cleanedName != original.name { return true }
        if clinicalHistory != original.clinicalHistory || notes != original.notes { return true }
        return showsMedications && cleanedMedications != original.medications
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Profile").font(.title2.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Name") {
                        TextField("Patient name", text: $name)
                            .textFieldStyle(.roundedBorder)
                        if cleanedName == nil {
                            Text("A name is required.").font(.caption).foregroundStyle(.red)
                        }
                    }

                    field("Clinical history", caption: "A short summary of the background. Shared with the AI.") {
                        EditorField(
                            text: $clinicalHistory,
                            placeholder: "Presenting concerns, diagnoses, prior treatment…",
                            minHeight: 100
                        )
                    }

                    if showsMedications { medicationsField }

                    field("Notes", caption: "Your own notes about this patient. Shared with the AI and included in exports.") {
                        EditorField(
                            text: $notes,
                            placeholder: "Anything worth remembering about this patient…",
                            minHeight: 120
                        )
                    }
                }
                .padding(.trailing, 4)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    if hasChanges { confirmDiscard = true } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(cleanedName == nil || !hasChanges)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 560)
        .interactiveDismissDisabled(hasChanges)
        .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private func save() {
        guard let cleanedName else { return }
        let meds = cleanedMedications
        appModel.updatePatient(id: patientID) { patient in
            patient.name = cleanedName
            patient.clinicalHistory = clinicalHistory
            patient.notes = notes
            // Without the medications module the table isn't shown, so what is
            // stored stays untouched.
            if showsMedications { patient.medications = meds }
        }
        dismiss()
    }

    @ViewBuilder
    private func field<Content: View>(
        _ title: String,
        caption: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var medicationsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Medications").font(.headline)
                Spacer()
                Button { medications.append(Medication()) } label: {
                    Label("Add Medication", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("Add a medication")
            }
            if medications.isEmpty {
                Text("None recorded.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach($medications) { $med in
                    HStack(spacing: 6) {
                        TextField("Medication", text: $med.name)
                        TextField("Dose", text: $med.dose).frame(width: 130)
                        Button(role: .destructive) {
                            medications.removeAll { $0.id == med.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
            }
        }
    }
}
