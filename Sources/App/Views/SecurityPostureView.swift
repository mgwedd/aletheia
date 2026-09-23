import AletheiaCore
import SwiftUI

/// The "Security overview" shown at the top of Settings: an at-a-glance,
/// plain-language read of how well protected the data is right now. It only
/// reflects state — every fix lives in the sections below (app lock, encryption,
/// backup) — so it reads without changing anything.
struct SecurityPostureView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var encryption: EncryptionManager
    @StateObject private var reachability = NetworkReachability()

    private var postureItems: [PostureItem] {
        SecurityPosture.evaluate(
            appLockEnabled: settings.appLockEnabled,
            canAuthenticate: AppLock.canAuthenticate(),
            idleAutoLockMinutes: settings.idleAutoLockMinutes,
            encryptionEnabled: encryption.isEnabled,
            encryptionUnlocked: encryption.isUnlocked,
            auditLogActive: appModel.audit != nil,
            localEncryptedBackup: settings.localEncryptedBackupEnabled,
            iCloudBackupEnabled: settings.iCloudEncryptedBackupEnabled,
            iCloudBackupConfigured: ICloudEncryptedBackupService.isProvisioned,
            networkOnline: reachability.isOnline
        )
    }

    var body: some View {
        let items = postureItems
        let overall = SecurityPosture.overall(items)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: Self.icon(for: overall))
                    .foregroundStyle(Self.color(for: overall))
                Text(Self.headline(for: overall)).font(.body.weight(.semibold))
            }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: Self.icon(for: item.level))
                        .foregroundStyle(Self.color(for: item.level))
                        .accessibilityHidden(true)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.callout.weight(.medium))
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private static func icon(for level: PostureLevel) -> String {
        switch level {
        case .secure: return "checkmark.shield.fill"
        case .actionRecommended: return "exclamationmark.shield.fill"
        case .informational: return "shield"
        }
    }

    private static func color(for level: PostureLevel) -> Color {
        switch level {
        case .secure: return .green
        case .actionRecommended: return .orange
        case .informational: return .secondary
        }
    }

    private static func headline(for level: PostureLevel) -> String {
        switch level {
        case .actionRecommended: return "Some protections could be stronger"
        case .secure: return "Your data is well protected on this Mac"
        case .informational: return "Security overview"
        }
    }
}
