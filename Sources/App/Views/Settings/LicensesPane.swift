import SwiftUI

/// Settings › Licenses: the third-party notices, read-only. The text is the
/// bundled copy of `THIRD-PARTY-NOTICES.md`.
struct LicensesPane: View {
    // Read once: the bundled file never changes while the app runs.
    private static let blocks = ThirdPartyNotices.load().map(ThirdPartyNotices.blocks(from:)) ?? []
    private var blocks: [ThirdPartyNotices.Block] { Self.blocks }

    var body: some View {
        if blocks.isEmpty {
            SettingsCard {
                SettingsCaption(ThirdPartyNotices.unavailableMessage)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .selectablePatientText()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func view(for block: ThirdPartyNotices.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(level <= 2 ? Theme.Typography.headline : Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.text.color)
                .padding(.top, level <= 2 ? 12 : 6)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(ThirdPartyNotices.linkified(text))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.text.color)
                .tint(Theme.accent.color)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            Text(ThirdPartyNotices.linkified(text))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .tint(Theme.accent.color)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.text.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .themeCard()
        }
    }
}
