import SwiftUI

/// The "Security posture" card in Settings → Security: an at-a-glance,
/// plain-language read of how well protected the data is right now. It only
/// reflects state — every fix lives in the other panes (app lock, encryption,
/// backups) — so it reads without changing anything.
struct SecurityPostureView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var encryption: EncryptionManager
    @StateObject private var reachability = NetworkReachability()

    private var postureItems: [PostureItem] {
        SecurityPosture.current(
            settings: settings, appModel: appModel, encryption: encryption,
            canAuthenticate: AppLock.canAuthenticate(), networkOnline: reachability.isOnline)
    }

    var body: some View {
        let items = postureItems
        let overall = SecurityPosture.overall(items)
        VStack(alignment: .leading, spacing: 12) {
            Text(SecurityPosture.headline(for: overall))
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.text.color)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { SettingsHairline() }
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(Theme.Typography.body.weight(.medium))
                                .foregroundStyle(Theme.text.color)
                            Text(item.detail)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.muted.color)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Chip(Self.chipText(for: item.level), tone: Self.chipTone(for: item.level))
                    }
                    .padding(.vertical, 11)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeCard()
        }
    }

    private static func chipText(for level: PostureLevel) -> String {
        switch level {
        case .secure: return "OK"
        case .actionRecommended: return "Review"
        case .informational: return "Info"
        }
    }

    private static func chipTone(for level: PostureLevel) -> Chip.Tone {
        switch level {
        case .secure: return .ok
        case .actionRecommended: return .warn
        case .informational: return .neutral
        }
    }
}
