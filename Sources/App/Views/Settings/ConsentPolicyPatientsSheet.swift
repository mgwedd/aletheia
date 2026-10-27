import SwiftUI

/// Settings > General > Apply to Patients…: one recording-consent policy for
/// the patients ticked, or Use default to clear their own.
struct ConsentPolicyPatientsSheet: View {
    let patients: [Patient]
    var onApply: (ConsentPolicy?, Set<UUID>) -> Void
    var onCancel: () -> Void

    @State private var edit = ConsentPolicyBulkEdit()

    private var ids: [UUID] { patients.map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recording consent for patients")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.text.color)
                .accessibilityAddTraits(.isHeader)
            Text("Their own policy replaces the Settings default. Use default clears it.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)

            ThemeSegmentedControl(
                options: ConsentPolicyChoice.allCases.map { ThemeTab(value: $0, title: $0.title) },
                selection: $edit.choice, sizing: .fitted)
                .accessibilityLabel("Recording consent")

            Toggle("Select All", isOn: Binding(
                get: { edit.allSelected(of: ids) },
                set: { edit.selectAll($0, of: ids) }))
                .toggleStyle(.checkbox)
                .font(Theme.Typography.body.weight(.medium))
                .foregroundStyle(Theme.text.color)
                .disabled(patients.isEmpty)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(patients) { patient in
                        Toggle(isOn: Binding(
                            get: { edit.selected.contains(patient.id) },
                            set: { _ in edit.toggle(patient.id) })) {
                            HStack {
                                Text(patient.name)
                                Spacer()
                                Text(ConsentPolicyChoice(patient.recordingConsentPolicy).title)
                                    .foregroundStyle(Theme.muted.color)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.text.color)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 280)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.themed)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(edit.choice.policy, edit.selected) }
                    .buttonStyle(.themePrimary)
                    .disabled(!edit.canApply)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.panel.color)
        .dismissOnLock { onCancel() }
    }
}
