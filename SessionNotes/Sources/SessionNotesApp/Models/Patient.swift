import Foundation

/// One medication the patient is on, shown as a name | dose row in the patient
/// view and fed to the AI as part of the patient's background.
struct Medication: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var dose: String

    init(id: UUID = UUID(), name: String = "", dose: String = "") {
        self.id = id
        self.name = name
        self.dose = dose
    }
}

struct Patient: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var notes: String
    let createdAt: Date
    /// Folder name on disk, e.g. "Jane-Doe" or "Jane-Doe-2" if the name collides.
    let slug: String
    /// The therapist's TL;DR of the patient's background (free text / Markdown).
    var clinicalHistory: String
    /// Current medications, name + dose.
    var medications: [Medication]

    init(
        id: UUID = UUID(),
        name: String,
        notes: String = "",
        createdAt: Date = Date(),
        slug: String,
        clinicalHistory: String = "",
        medications: [Medication] = []
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.slug = slug
        self.clinicalHistory = clinicalHistory
        self.medications = medications
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, notes, createdAt, slug, clinicalHistory, medications
    }

    // Custom decoding so patient.json files written before these fields existed
    // still load (the new fields default to empty).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        slug = try c.decode(String.self, forKey: .slug)
        clinicalHistory = try c.decodeIfPresent(String.self, forKey: .clinicalHistory) ?? ""
        medications = try c.decodeIfPresent([Medication].self, forKey: .medications) ?? []
    }

    /// The always-included background block handed to the AI so it can weigh the
    /// therapist's summary and the patient's medications. Empty when nothing has
    /// been entered, so it adds nothing to the prompt. Pure, so it's unit-tested.
    var aiBackgroundBlock: String {
        var lines: [String] = []
        let history = clinicalHistory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !history.isEmpty {
            lines.append("Clinical history (therapist's summary):\n\(history)")
        }
        let meds = medications
            .map { ($0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    $0.dose.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.0.isEmpty }
        if !meds.isEmpty {
            let rows = meds.map { name, dose in dose.isEmpty ? "- \(name)" : "- \(name): \(dose)" }
            lines.append("Current medications:\n" + rows.joined(separator: "\n"))
        }
        guard !lines.isEmpty else { return "" }
        return "===== Patient background =====\n" + lines.joined(separator: "\n\n")
    }
}
