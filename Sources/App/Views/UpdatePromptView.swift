import SwiftUI

/// Turns the release feed's free-form notes into short bullet lines: blank
/// lines and markdown headings are dropped and list markers ("-", "*", "•")
/// are stripped, so the view can draw its own bullets.
enum ReleaseNotesFormatter {
    static func items(from notes: String) -> [String] {
        notes
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> String? in
                var line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
                for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                    line = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
                return line.isEmpty ? nil : line
            }
    }
}

struct UpdatePromptView: View {
    let release: ReleaseInfo
    let onUpdate: () -> Void
    let onSkip: () -> Void
    let onLater: () -> Void

    private var notes: [String] { ReleaseNotesFormatter.items(from: release.releaseNotes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.accent.color)
                    .frame(width: 48, height: 48)
                    .background(Theme.accentTint.color, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aletheia \(release.version) is available")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("You have \(UpdateService.bundleVersion().description).")
                        .font(Theme.Typography.control.weight(.regular))
                        .foregroundStyle(Theme.muted.color)
                }
            }

            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What is new").eyebrowStyle()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(notes.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•")
                                        .foregroundStyle(Theme.muted.color)
                                    Text(item)
                                        .foregroundStyle(Theme.text.color)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                                .font(Theme.Typography.body)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Skip this version", action: onSkip)
                    .buttonStyle(.plain)
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.muted.color)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                Button("Remind me later", role: .cancel, action: onLater)
                    .buttonStyle(.themed)
                Button("Download update", action: onUpdate)
                    .buttonStyle(.themePrimary)
                    .keyboardShortcut(.defaultAction)
            }

            Text("Download update starts the download and closes this window. Aletheia stays open so you can finish and save your work; quit it when you're ready, then drag the new version into your Applications folder to replace this one. The version check sent no client data.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(width: 480)
        .background(Theme.panel.color)
    }
}
