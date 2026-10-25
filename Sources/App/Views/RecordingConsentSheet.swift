import SwiftUI

/// Asked once per patient, before their first recording: the clinician attests
/// that the patient agreed to be recorded and to AI processing of the
/// recording. Aletheia stores the date of the attestation, not the consent
/// itself.
struct RecordingConsentSheet: View {
    var onCancel: () -> Void
    var onConfirm: () -> Void

    @State private var confirmed = false
    @State private var showConsentGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before you record")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.text.color)
                .accessibilityAddTraits(.isHeader)
            Text("Confirm that this patient has agreed to be recorded, and to have the recording transcribed and processed by AI on this Mac. You are only asked once for each patient.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(RecordingConsent.attestationText, isOn: $confirmed)
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
                Button("Start recording", action: onConfirm)
                    .buttonStyle(.themePrimary)
                    .disabled(!confirmed)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.panel.color)
        .dismissOnLock { showConsentGuide = false; onCancel() }
        .sheet(isPresented: $showConsentGuide) { ConsentGuideView() }
    }
}
