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

/// Sizes and labels of the update prompt's action rows, shared with the view
/// so a test can measure the real strings. The buttons are single-line (the
/// themed style sets `lineLimit(1)`), so a row wider than the prompt truncates
/// its labels ("Remind m...") instead of wrapping them.
enum UpdatePromptLayout {
    static let width: CGFloat = 480
    static let padding: CGFloat = 28
    static var contentWidth: CGFloat { width - 2 * padding }
    static let rowSpacing: CGFloat = 8

    static let viewOnGitHub = "View on GitHub"
    static let skip = "Skip this version"
    static let later = "Remind me later"
    static let download = "Download update"

    /// Links on the first row, buttons on the second: four controls in one row
    /// need more than the prompt's width.
    static let rows = [[viewOnGitHub, skip], [later, download]]
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

            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    Link(UpdatePromptLayout.viewOnGitHub, destination: release.releasePageOrWebURL)
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.accent.color)
                    Button(UpdatePromptLayout.skip, action: onSkip)
                        .buttonStyle(.plain)
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.muted.color)
                        .contentShape(Rectangle())
                    Spacer(minLength: 0)
                }
                HStack(spacing: UpdatePromptLayout.rowSpacing) {
                    Spacer(minLength: 0)
                    Button(UpdatePromptLayout.later, role: .cancel, action: onLater)
                        .buttonStyle(.themed)
                    Button(UpdatePromptLayout.download, action: onUpdate)
                        .buttonStyle(.themePrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }

            Text("Download update starts the download and closes this window. Aletheia stays open so you can finish and save your work; quit it when you're ready, then drag the new version into your Applications folder to replace this one. The version check sent no client data.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UpdatePromptLayout.padding)
        .frame(width: UpdatePromptLayout.width)
        .background(Theme.panel.color)
        .textSelection(.enabled)
    }
}
