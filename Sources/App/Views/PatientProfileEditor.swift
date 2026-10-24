import SwiftUI

/// The boxes in the profile editor. Opening the editor from a field on the
/// patient view focuses that box.
enum ProfileField: Equatable {
    case name, clinicalHistory, medications, notes

    /// The box for a row of the profile card (`Patient.profileRows` labels).
    init(rowLabel: String) {
        switch rowLabel {
        case "Clinical history": self = .clinicalHistory
        case "Medications": self = .medications
        case "Notes": self = .notes
        default: self = .name
        }
    }

    /// The medication row to focus when the editor opens on Medications: the
    /// first one. `nil` for any other box, or when there are no medications.
    func medicationToFocus(in medications: [Medication]) -> UUID? {
        self == .medications ? medications.first?.id : nil
    }
}

/// Sheet for editing a patient's name, clinical history, medications and notes.
/// Nothing is written until Save; Cancel with unsaved changes asks first. The
/// whole profile is saved in one `updatePatient` call.
struct PatientProfileEditor: View {
    private let patientID: UUID
    private let original: Patient
    private let showsMedications: Bool
    private let initialFocus: ProfileField
    private let onLockDraft: (Patient?) -> Void

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var clinicalHistory: String
    @State private var notes: String
    @State private var medications: [Medication]
    @State private var confirmDiscard = false
    @State private var showDeleteConfirmation = false
    @State private var deleteErrorMessage: String?

    /// `draft` carries unsaved edits kept when the app locked closed this sheet;
    /// `onLockDraft` receives the edits if it closes that way again, and nil once
    /// a draft has been taken up.
    init(
        patient: Patient, showsMedications: Bool, initialFocus: ProfileField = .name,
        draft: Patient? = nil, onLockDraft: @escaping (Patient?) -> Void = { _ in }
    ) {
        self.initialFocus = initialFocus
        self.onLockDraft = onLockDraft
        patientID = patient.id
        original = patient
        self.showsMedications = showsMedications
        let shown = draft ?? patient
        _name = State(initialValue: shown.name)
        _clinicalHistory = State(initialValue: shown.clinicalHistory)
        _notes = State(initialValue: shown.notes)
        _medications = State(initialValue: shown.medications)
    }

    /// The fields as currently typed, on top of the saved patient.
    private var currentDraft: Patient {
        var patient = original
        patient.name = name
        patient.clinicalHistory = clinicalHistory
        patient.notes = notes
        patient.medications = medications
        return patient
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
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Name") {
                        ProfileTextField(placeholder: "Patient name", label: "Name", text: $name, autofocus: initialFocus == .name)
                            .frame(height: 40)
                        if cleanedName == nil {
                            Text("A name is required.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.recording.color)
                        }
                    }

                    field("Patient notes") {
                        EditorField(
                            text: $notes,
                            placeholder: "Anything worth remembering about this patient…",
                            minHeight: 84,
                            autofocus: initialFocus == .notes
                        )
                        infoCaption("Your own notes about this patient. Available to the AI and included in exports.")
                    }

                    field("Clinical history") {
                        EditorField(
                            text: $clinicalHistory,
                            placeholder: "Presenting concerns, diagnoses, prior treatment…",
                            minHeight: 100,
                            autofocus: initialFocus == .clinicalHistory
                        )
                        infoCaption("A short summary of the background. Saved with the patient and available to the AI.")
                    }

                    if showsMedications { medicationsField }

                    removePatientSection
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }

            footer
        }
        .frame(width: 560, height: 640)
        .background(Theme.panel.color)
        .tint(Theme.accent.color)
        .interactiveDismissDisabled(hasChanges)
        .onAppear { onLockDraft(nil) }
        // Locking closes the editor. Unsaved edits are kept in memory (not written)
        // so reopening this patient's editor does not lose them.
        .dismissOnLock {
            onLockDraft(hasChanges ? currentDraft : nil)
            dismiss()
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .sheet(isPresented: $showDeleteConfirmation) {
            DeletePatientConfirmationView(patient: original) {
                showDeleteConfirmation = false
                do {
                    try appModel.deletePatient(original)
                    dismiss()
                } catch {
                    deleteErrorMessage = error.localizedDescription
                }
            }
        }
        .alert(
            "Unable to delete patient",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text("Edit patient")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.text.color)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: requestClose) {
                Label("Close", systemImage: "xmark")
            }
            .buttonStyle(.themeIcon)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel", role: .cancel, action: requestClose)
                .buttonStyle(.themed)
                .keyboardShortcut(.cancelAction)
            Button("Save changes", action: save)
                .buttonStyle(.themePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Theme.sidebar.color)
        .themeDivider(.top)
        // Keeps Command-S working now that Return is the default action.
        .background {
            Button("Save", action: save)
                .keyboardShortcut(AppHotkey.saveEdits)
                .disabled(!canSave)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var canSave: Bool { cleanedName != nil && hasChanges }

    private func requestClose() {
        if hasChanges { confirmDiscard = true } else { dismiss() }
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
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).eyebrowStyle()
            content()
        }
    }

    /// A muted note under a field, led by an info glyph.
    private func infoCaption(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Typography.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.muted.color)
        .accessibilityElement(children: .combine)
    }

    private var medicationsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Medications").eyebrowStyle()
                Spacer()
                Button { medications.append(Medication()) } label: {
                    Label("Add medication", systemImage: "plus")
                }
                .buttonStyle(.themeIcon)
                .controlSize(.small)
                .help("Add a medication")
            }
            if medications.isEmpty {
                Text("None recorded.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted.color)
            } else {
                ForEach($medications) { $med in
                    HStack(spacing: 8) {
                        ProfileTextField(
                            placeholder: "Medication",
                            label: "Medication name",
                            text: $med.name,
                            autofocus: initialFocus.medicationToFocus(in: medications) == med.id
                        )
                        ProfileTextField(placeholder: "Dose", label: "Dose", text: $med.dose)
                            .frame(width: 130)
                        Button {
                            medications.removeAll { $0.id == med.id }
                        } label: {
                            Label("Remove medication", systemImage: "trash")
                        }
                        .buttonStyle(.themeIcon)
                        .help("Remove")
                    }
                    .frame(height: 38)
                }
            }
        }
    }

    private var removePatientSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remove patient").eyebrowStyle()
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Delete this patient and all data")
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.text.color)
                        Text("Permanently removes this patient, along with all of their sessions, transcripts, audio recordings, and notes. This cannot be undone.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.muted.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Button("Delete patient…") {
                        showDeleteConfirmation = true
                    }
                    .buttonStyle(.themeRecording)
                    .controlSize(.small)
                }
            }
            .padding(14)
            .background(Theme.recordingTint.color.opacity(0.35))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.recording.color.opacity(0.4), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.top, 8)
    }
}

/// Destructive confirmation sheet for permanently deleting a patient.
/// Requires typing the patient's name to confirm.
struct DeletePatientConfirmationView: View {
    let patient: Patient
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""
    @FocusState private var isFieldFocused: Bool

    private var matches: Bool {
        typedName.trimmingCharacters(in: .whitespaces)
            .localizedCaseInsensitiveCompare(patient.name) == .orderedSame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Delete \(patient.name)?")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.text.color)
                    Text("This will permanently delete this patient and all of their recorded sessions, clinical notes, transcripts, audio, and AI conversations from disk.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.recording.color)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("To confirm, type the patient's name below:")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)

                TextField.patient(patient.name, text: $typedName, focus: $isFieldFocused)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .themeField(isFocused: isFieldFocused)
                    .accessibilityLabel("Type patient name to confirm deletion")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .buttonStyle(.themed)
                .keyboardShortcut(.cancelAction)

                Button("Delete Patient") {
                    onDelete()
                }
                .buttonStyle(.themeRecording)
                .disabled(!matches)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.panel.color)
        .onAppear {
            isFieldFocused = true
        }
    }
}

/// A single-line text field in the design's field box (field fill, hairline
/// border, accent border while focused).
private struct ProfileTextField: View {
    let placeholder: String
    let label: String
    @Binding var text: String
    var autofocus = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField.patient(placeholder, text: $text, focus: $focused)
            .textFieldStyle(.plain)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.text.color)
            .autofocusAtEnd(autofocus, focus: $focused)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .themeField(isFocused: focused)
            .accessibilityLabel(label)
    }
}
