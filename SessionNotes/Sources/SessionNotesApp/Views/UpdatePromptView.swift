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
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update Available").font(.title2.bold())
                    Text("Version \(release.version) is ready.").foregroundStyle(.secondary)
                }
            }

            if !release.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("What's New").font(.headline)
                ScrollView {
                    Text(release.releaseNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            }

            Text("Update opens the download. Quit Session Notes, then drag the new version into your Applications folder to replace this one.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Skip This Version", role: .cancel, action: onSkip)
                Spacer()
                Button("Later", action: onLater)
                Button("Update", action: onUpdate).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
