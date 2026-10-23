import SwiftUI

/// Paste field for a license key, with a clear message for each way it can be refused.
/// Used by first-run and Settings > License key. Checks entirely on this Mac.
struct LicenseEntryView: View {
    @EnvironmentObject private var license: LicenseState
    var buttonTitle = "Check license"
    var onInstalled: (LicenseToken) -> Void = { _ in }

    @State private var text = ""
    @State private var error: LicenseError?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ThemeTextField(
                    placeholder: "Paste your license key (starts with ALET1)",
                    text: $text,
                    accessibilityLabel: "License key",
                    onSubmit: submit)
                Button(buttonTitle, action: submit)
                    .buttonStyle(.themePrimary)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error {
                Label(error.errorDescription ?? "The license key was not accepted.", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.recording.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func submit() {
        switch license.install(text) {
        case .success(let token):
            error = nil
            text = ""
            onInstalled(token)
        case .failure(let failure):
            error = failure
        }
    }
}

/// A non-blocking strip above the main window: the license is close to expiring,
/// or has lapsed. Reading, searching, exporting and deleting records are unaffected.
struct LicenseBanner: View {
    let status: LicenseStatus
    let onOpenSettings: () -> Void

    var body: some View {
        if let text = Self.text(for: status) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warn.color)
                Text(text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("License…", action: onOpenSettings)
                    .buttonStyle(.themed)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.callout.color)
            .themeDivider(.bottom)
            .accessibilityElement(children: .combine)
        }
    }

    /// The strip's words for a status, or nil when there is nothing to say.
    static func text(for status: LicenseStatus) -> String? {
        switch status {
        case .valid:
            return nil
        case .expiringSoon(let token, let days):
            let when = days == 1 ? "tomorrow" : "in \(days) days"
            return "Your license expires \(when) (\(token.expiresAt.licenseText)). Request a new key before then to keep recording and using the AI."
        case .gracePeriod(let token, let days):
            let left = days == 1 ? "1 more day" : "\(days) more days"
            return "Your license expired on \(token.expiresAt.licenseText). Recording and the AI keep working for \(left) (until \(token.graceEndsAt.licenseText)); add a new key in Settings > License key before then."
        case .expired(let token):
            return "Your license expired on \(token.expiresAt.licenseText). New recordings and the AI are paused; everything you have already recorded stays open, searchable and exportable."
        case .revoked:
            return "Your license is no longer valid. New recordings and the AI are paused; everything you have already recorded stays open, searchable and exportable."
        case .grandfathered:
            return "Add your license key in Settings > License key. Recording and the AI keep working meanwhile."
        case .unlicensed:
            return "Add a license key to record or use the AI. Everything you have already recorded stays open, searchable and exportable."
        case .invalid(let error):
            return "\(error.errorDescription ?? "The license key could not be verified.") New recordings and the AI are paused; your existing records are unaffected."
        }
    }
}

/// Settings > License key: who the license is for, when it ends, and a field to replace it.
struct LicensePane: View {
    @EnvironmentObject private var license: LicenseState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("License").eyebrowStyle()
            SettingsRowsCard {
                SettingsRow(title: "Status") { statusChip }
                    .padding(.vertical, 12)
                if let token = license.status.token {
                    SettingsHairline()
                    SettingsRow(title: "Licensed to") {
                        Text(token.sub)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.text.color)
                    }
                    .padding(.vertical, 12)
                    SettingsHairline()
                    SettingsRow(title: "Tier") {
                        Text(token.tier.capitalized)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.text.color)
                    }
                    .padding(.vertical, 12)
                    SettingsHairline()
                    SettingsRow(title: expiryTitle) {
                        Text(token.expiresAt.licenseText)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.text.color)
                    }
                    .padding(.vertical, 12)
                }
            }
            if let text = LicenseBanner.text(for: license.status) {
                SettingsCaption(text)
            }
        }
        SettingsHairline()
        VStack(alignment: .leading, spacing: 8) {
            Text("Replace license key").eyebrowStyle()
            SettingsCard {
                LicenseEntryView(buttonTitle: "Replace")
                SettingsCaption("The key is checked on this Mac. It is never sent anywhere, and nothing about it leaves the app.")
            }
        }
    }

    private var expiryTitle: String {
        switch license.status {
        case .gracePeriod, .expired, .revoked: return "Ended"
        default: return "Expires"
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch license.status {
        case .valid: Chip("Active", tone: .ok)
        case .expiringSoon: Chip("Expiring soon", tone: .warn)
        case .gracePeriod: Chip("Grace period", tone: .warn)
        case .expired: Chip("Expired", tone: .recording)
        case .revoked: Chip("Not valid", tone: .recording)
        case .invalid: Chip("Not valid", tone: .recording)
        case .unlicensed, .grandfathered: Chip("No license", tone: .warn)
        }
    }
}
