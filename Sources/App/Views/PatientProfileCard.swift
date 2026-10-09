import SwiftUI

/// The patient's profile at a glance: a short read-only preview of clinical
/// history, medications and notes, with an Edit button. Editing happens in
/// `PatientProfileEditor`, which saves only on an explicit Save.
struct PatientProfileCard: View {
    let patient: Patient
    let showsMedications: Bool
    let onEdit: () -> Void

    var body: some View {
        let rows = patient.profileRows(includeMedications: showsMedications)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Profile").font(.headline)
                Spacer()
                Button("Edit", action: onEdit)
                    .help("Edit name, clinical history, medications and notes")
            }
            if rows.isEmpty {
                Text("Nothing recorded yet. Edit to add clinical history or notes; both are shared with the AI.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.label) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label).font(.caption).foregroundStyle(.secondary)
                        Text(row.text)
                            .font(.callout)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}
