import Foundation

/// The patient medications (name | dose) table as a `FeatureModule`.
///
/// Complete and working, but non-core to the record → transcribe → summarize →
/// notes → chat loop, so it ships from `.preview` rather than `.production`.
///
/// Gating hides only the editing UI (the "Medications" table in the patient
/// Background section). Any medications already stored on a patient are left
/// untouched — never deleted — and remain part of the patient record; a build
/// without this module simply doesn't display or edit them. This keeps the carve
/// data-integrity safe: withholding the feature can't lose data.
struct PatientMedicationsFeatureModule: FeatureModule {
    /// Also usable as `PatientMedicationsFeatureModule.id` at call sites that only
    /// need the identifier to query the registry, without constructing an instance.
    static let id = "patientMedications"

    var id: String { Self.id }
    let title = "Medications"
    let tier: BuildTier = .preview
}
