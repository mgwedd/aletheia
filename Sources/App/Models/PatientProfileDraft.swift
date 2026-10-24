import Foundation

/// The profile editor's working copy of a patient: what has been typed so far,
/// and the rules for when it can be saved, whether closing needs a second
/// thought, and what a save writes. Nothing here touches disk; the editor
/// applies `apply(to:)` through `AppModel.updatePatient`. Pure, so it's
/// unit-tested.
struct PatientProfileDraft: Equatable {
    static let blankNameMessage = "A name is required."
    static let nothingRecordedMessage = "Nothing recorded yet. Edit to add clinical history or notes; both are available to the AI."
    static let noMedicationsMessage = "None recorded."

    let original: Patient
    /// False when the build has no medications module: the table is hidden and
    /// stored medications are left alone on save.
    let showsMedications: Bool
    var name: String
    var clinicalHistory: String
    var notes: String
    var medications: [Medication]

    init(patient: Patient, showsMedications: Bool) {
        original = patient
        self.showsMedications = showsMedications
        name = patient.name
        clinicalHistory = patient.clinicalHistory
        notes = patient.notes
        medications = patient.medications
    }

    /// The name as it would be saved; nil while it is blank.
    var cleanedName: String? { Patient.normalizedName(name) }

    /// Medication rows with something typed in either box.
    var cleanedMedications: [Medication] {
        medications.filter { !($0.name.trimmingCharacters(in: .whitespaces).isEmpty
            && $0.dose.trimmingCharacters(in: .whitespaces).isEmpty) }
    }

    var hasChanges: Bool {
        if let cleanedName, cleanedName != original.name { return true }
        if clinicalHistory != original.clinicalHistory || notes != original.notes { return true }
        return showsMedications && cleanedMedications != original.medications
    }

    var canSave: Bool { cleanedName != nil && hasChanges }

    /// Shown under the name box while it is blank.
    var nameProblem: String? { cleanedName == nil ? Self.blankNameMessage : nil }

    /// Closing with unsaved changes asks "Discard your changes?" first.
    var needsDiscardConfirmation: Bool { hasChanges }

    mutating func addMedication() { medications.append(Medication()) }

    mutating func removeMedication(id: UUID) { medications.removeAll { $0.id == id } }

    /// Writes the draft into `patient`. Medications are only touched when the
    /// table was shown.
    func apply(to patient: inout Patient) {
        guard let cleanedName else { return }
        patient.name = cleanedName
        patient.clinicalHistory = clinicalHistory
        patient.notes = notes
        if showsMedications { patient.medications = cleanedMedications }
    }
}

/// Whether what was typed in the delete-patient confirmation names the patient
/// (trimmed, case-insensitive).
enum PatientDeletionConfirmation {
    static func matches(typed: String, patientName: String) -> Bool {
        typed.trimmingCharacters(in: .whitespaces)
            .localizedCaseInsensitiveCompare(patientName) == .orderedSame
    }
}

/// The session counts shown next to a patient.
enum PatientSessionText {
    /// Patient page header: "No sessions", "1 session", "N sessions".
    static func summary(count: Int) -> String {
        switch count {
        case 0: return "No sessions"
        case 1: return "1 session"
        default: return "\(count) sessions"
        }
    }

    /// Sidebar row subtitle: "N sessions · Mon d" for the newest session, or
    /// "Added Mon yyyy" when there are none.
    static func rowSubtitle(patient: Patient, count: Int, newest: Date?, locale: Locale = .current) -> String {
        if count > 0 {
            let word = count == 1 ? "1 session" : "\(count) sessions"
            if let newest { return "\(word) · \(format(newest, "MMM d", locale))" }
            return word
        }
        return "Added \(format(patient.createdAt, "MMM yyyy", locale))"
    }

    private static func format(_ date: Date, _ template: String, _ locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
