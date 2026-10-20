import SwiftUI

/// A clinical and legal guide on obtaining informed client consent before
/// recording therapy sessions, both in-person and over telehealth.
struct ConsentGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introBox

                    section(
                        title: "1. Informed Consent Standards",
                        icon: "doc.text.magnifyingglass",
                        content: "Professional ethics codes (including APA, ACA, NASW, and AAMFT) require obtaining explicit informed consent before recording therapy sessions in any medium. Inform your client of the purpose of the recording, how transcripts are generated, and who has access."
                    )

                    section(
                        title: "2. Jurisdiction & Wiretapping Laws",
                        icon: "building.columns",
                        content: "Many states and jurisdictions require two-party (all-party) consent to record conversations. Because telehealth sessions may cross state lines, follow the strictest applicable jurisdiction's consent laws."
                    )

                    section(
                        title: "3. On-Device Privacy Guarantees",
                        icon: "lock.shield",
                        content: "Explain to your client that Aletheia operates 100% on this Mac: speech recognition and AI note drafting run locally. No audio, transcripts, or notes are uploaded to any cloud server or third-party service."
                    )

                    section(
                        title: "4. Client Rights & Revocation",
                        icon: "hand.raised",
                        content: "Clients have the right to decline recording, ask to pause or stop recording at any point during a session, or request that previous session recordings or transcripts be deleted from your records."
                    )

                    disclosureSampleBox
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }

            footer
        }
        .frame(width: 580, height: 620)
        .background(Theme.panel.color)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Client Consent Guide")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.text.color)
                    .accessibilityAddTraits(.isHeader)
                Text("Best practices for recording in-person and telehealth sessions")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .buttonStyle(.themeIcon)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .themeDivider(.bottom)
    }

    private var introBox: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent.color)
                .padding(.top, 2)
            Text("Aletheia is a software tool, not legal or clinical advice. Always adhere to your state laws, professional licensing board rules, and clinic policies.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.text.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Theme.field.color)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.line.color, lineWidth: 1)
        )
    }

    private func section(title: String, icon: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent.color)
                Text(title)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.text.color)
            }
            Text(content)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var disclosureSampleBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SAMPLE INFORMED CONSENT CLAUSE").eyebrowStyle()
            Text("“I use an on-device clinical documentation tool (Aletheia) to transcribe our session audio and assist in preparing clinical progress notes. All audio and notes remain strictly on this computer and are never sent to external servers or cloud AI providers. You may request to pause or stop recording at any time.”")
                .font(Theme.Typography.noteBody)
                .foregroundStyle(Theme.text.color)
                .padding(12)
                .background(Theme.raised.color)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.line.color, lineWidth: 1)
                )
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.themePrimary)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(Theme.sidebar.color)
        .themeDivider(.top)
    }
}
