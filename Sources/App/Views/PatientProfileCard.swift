import SwiftUI

/// The patient's profile at a glance: a short read-only preview of clinical
/// history, medications and notes, with an Edit button. Clicking any field
/// opens the editor too. Editing happens in
/// `PatientProfileEditor`, which saves only on an explicit Save.
struct PatientProfileCard: View {
    let patient: Patient
    let showsMedications: Bool
    /// Opens the editor with the given box focused.
    let onEdit: (ProfileField) -> Void

    /// The model calls the therapist's own notes "Notes"; in this column they
    /// are set apart from the session notes as "Patient notes".
    private func displayLabel(_ label: String) -> String {
        label == "Notes" ? "Patient notes" : label
    }

    var body: some View {
        let rows = patient.profileRows(includeMedications: showsMedications)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Profile").eyebrowStyle()
                Spacer()
                Button("Edit") { onEdit(.name) }
                    .buttonStyle(.themed)
                    .controlSize(.small)
                    .help("Edit name, clinical history, medications and notes")
            }
            if rows.isEmpty {
                Text("Nothing recorded yet. Edit to add clinical history or notes; both are available to the local AI model.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(rows, id: \.label) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayLabel(row.label)).eyebrowStyle()
                        // A single click opens the editor, like the Edit button.
                        Button { onEdit(ProfileField(rowLabel: row.label)) } label: {
                            Text(row.text)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.text.color)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .themeField()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Click to edit")
                        .accessibilityLabel("\(displayLabel(row.label)): \(row.text)")
                        .accessibilityHint("Opens the editor")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
