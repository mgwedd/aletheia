import SwiftUI

/// Record consent: who agreed to the recording, how, and when, with the
/// clinician's confirmation. Shown before Record Session and Import Audio…
/// when the consent policy asks, and from Change… on the session screen.
struct RecordingConsentSheet: View {
    let purpose: ConsentSheetPurpose
    let policy: ConsentPolicy
    var onCancel: () -> Void
    var onConfirm: (ConsentCapture) -> Void

    @State private var capture = ConsentCapture()
    @State private var showConsentGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(RecordingConsent.sheetTitle)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.text.color)
                .accessibilityAddTraits(.isHeader)
            Text(RecordingConsent.sheetExplanation(policy))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)

            labelled("Who consented") {
                Picker("Who consented", selection: $capture.party) {
                    ForEach(ConsentParty.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            if capture.party.needsName {
                labelled("Name") {
                    ThemeTextField(placeholder: "Name", text: $capture.name)
                }
            }
            labelled("How") {
                ThemeSegmentedControl(
                    options: ConsentMethod.allCases.map { ThemeTab(value: $0, title: $0.title) },
                    selection: $capture.method, sizing: .fitted)
            }
            labelled("When") {
                DatePicker("When", selection: $capture.consentedAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }

            Toggle(RecordingConsent.attestationText, isOn: $capture.confirmed)
                .toggleStyle(.checkbox)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.text.color)
            Button("Read the consent guide…") { showConsentGuide = true }
                .buttonStyle(.themed)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.themed)
                    .keyboardShortcut(.cancelAction)
                Button(purpose.confirmTitle) { onConfirm(capture) }
                    .buttonStyle(.themePrimary)
                    .disabled(!capture.isComplete)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.panel.color)
        .dismissOnLock { showConsentGuide = false; onCancel() }
        .sheet(isPresented: $showConsentGuide) { ConsentGuideView() }
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.Typography.sectionLabel)
                .foregroundStyle(Theme.muted.color)
            content()
        }
    }
}
