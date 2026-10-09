import SwiftUI

struct UpdatePromptView: View {
    let release: ReleaseInfo
    let onUpdate: () -> Void
    let onSkip: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.accent.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update Available")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.text.color)
                    Text("Version \(release.version) is ready.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted.color)
                }
            }

            if !release.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("What's New")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.text.color)
                ScrollView {
                    Text(release.releaseNotes)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.text.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chip.color))
            }

            Text("Update starts the download and closes this window. Aletheia stays open so you can finish and save your work; quit it when you're ready, then drag the new version into your Applications folder to replace this one.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)

            HStack {
                Button("Skip This Version", role: .cancel, action: onSkip)
                    .buttonStyle(.themed)
                Spacer()
                Button("Later", action: onLater)
                    .buttonStyle(.themed)
                Button("Update", action: onUpdate)
                    .buttonStyle(.themePrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.window.color)
    }
}
