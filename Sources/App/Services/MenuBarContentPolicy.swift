import Foundation

enum MenuBarContentPolicy {
    static func canStartRecording(isLocked: Bool, isStarting: Bool) -> Bool {
        !isLocked && !isStarting
    }

    /// How a patient reads in the menu bar: initials unless the clinician opted
    /// in to names and the app is unlocked.
    static func patientLabel(name: String, showFullName: Bool, isLocked: Bool) -> String {
        PatientLabel.text(forName: name, surface: .menuBar,
                          policy: .init(showFullName: showFullName, isLocked: isLocked))
    }

    /// One label per patient for the picker. When initials collide, the label
    /// gains the date the patient was added (never the name) so the rows can be
    /// told apart; any rows still identical get a number.
    static func pickerLabels(
        _ patients: [(id: UUID, name: String, addedOn: Date)],
        showFullName: Bool,
        isLocked: Bool
    ) -> [UUID: String] {
        let base = patients.map { patientLabel(name: $0.name, showFullName: showFullName, isLocked: isLocked) }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        var counts: [String: Int] = [:]
        base.forEach { counts[$0, default: 0] += 1 }
        var labels: [UUID: String] = [:]
        var seen: [String: Int] = [:]
        for (index, patient) in patients.enumerated() {
            var label = base[index]
            if counts[label, default: 0] > 1 {
                label += " · added \(formatter.string(from: patient.addedOn))"
                seen[label, default: 0] += 1
                if seen[label]! > 1 { label += " (\(seen[label]!))" }
            }
            labels[patient.id] = label
        }
        return labels
    }
}
