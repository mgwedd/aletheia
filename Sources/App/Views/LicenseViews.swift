import AppKit
import SwiftUI

/// Web pages the license screens link to. They open in the browser; the app sends nothing.
enum LicenseLinks {
    /// Where a lost, expired or missing key is emailed again.
    static let requestKey = URL(string: "https://astrealabs.com/aletheia/beta")!
}

/// Paste field for a license key, with a clear message for each way it can be refused.
/// Used by first-run and Settings > License key. Checks entirely on this Mac.
struct LicenseEntryView: View {
    @EnvironmentObject private var license: LicenseState
    @ObservedObject private var navigator = AppNavigator.shared
    var buttonTitle = "Check license"
    var onInstalled: (LicenseToken) -> Void = { _ in }

    @State private var text = ""
    @State private var error: LicenseError?
    /// What the key from an "Open in Aletheia" link turned out to be, until it is
    /// installed or the field changes.
    @State private var offered: (text: String, result: Result<LicenseToken, LicenseError>)?

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
            if let offered, offered.text == text {
                Text(Self.offerText(offered.result, buttonTitle: buttonTitle))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error.errorDescription ?? "The license key was not accepted.", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.recording.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { takeOfferedKey() }
        .onChange(of: navigator.offeredLicenseKey) { _, _ in takeOfferedKey() }
    }

    /// Fills the field from an "Open in Aletheia" link. Nothing is installed until
    /// the user clicks the button.
    private func takeOfferedKey() {
        guard let key = navigator.takeOfferedLicenseKey() else { return }
        text = key
        error = nil
        offered = (key, license.check(key))
    }

    /// The line under a key that came from a link: whose it is, or why it won't do.
    static func offerText(_ result: Result<LicenseToken, LicenseError>, buttonTitle: String) -> String {
        switch result {
        case .success(let token):
            return "Key from your browser, licensed to \(token.sub) until \(token.expiresAt.licenseText). Click \u{201C}\(buttonTitle)\u{201D} to use it."
        case .failure(let error):
            return "Key from your browser: \(error.errorDescription ?? "it was not accepted.")"
        }
    }

    private func submit() {
        switch license.install(text) {
        case .success(let token):
            error = nil
            offered = nil
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
    var onExportRecords: () -> Void = {}

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
                if Self.offersExport(for: status) {
                    Button("Export All Records…", action: onExportRecords)
                        .buttonStyle(.themed)
                        .controlSize(.small)
                }
                if Self.offersNewKey(for: status) {
                    Button("Get a Key…") { NSWorkspace.shared.open(LicenseLinks.requestKey) }
                        .buttonStyle(.themed)
                        .controlSize(.small)
                }
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

    /// Recording and the AI are paused: offer to export the records, which always works.
    static func offersExport(for status: LicenseStatus) -> Bool {
        switch status {
        case .expired, .revoked, .unlicensed, .invalid: return true
        case .valid, .expiringSoon, .gracePeriod, .grandfathered: return false
        }
    }

    /// Whenever a key is missing, ending or no good: link to the page that sends one.
    static func offersNewKey(for status: LicenseStatus) -> Bool {
        if case .valid = status { return false }
        return true
    }

    /// The strip's words for a status, or nil when there is nothing to say.
    static func text(for status: LicenseStatus) -> String? {
        switch status {
        case .valid:
            return nil
        case .expiringSoon(let token, let days):
            let when = days == 1 ? "tomorrow" : "in \(days) days"
            return "Your license expires \(when) (\(token.expiresAt.licenseText)). A renewed key is emailed to you before then: paste it in Settings > License key."
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
    @EnvironmentObject private var settings: AppSettings

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
                    if let terms = license.termsSummary {
                        ForEach(terms.rows, id: \.document) { row in
                            SettingsHairline()
                            SettingsRow(title: row.document.title) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(row.text)
                                        .font(Theme.Typography.body)
                                        .foregroundStyle(Theme.text.color)
                                    if row.matchesThisVersion {
                                        Text(LicenseTermsSummary.matchText)
                                            .font(Theme.Typography.caption)
                                            .foregroundStyle(Theme.muted.color)
                                    }
                                }
                            }
                            .padding(.vertical, 12)
                        }
                        if !terms.licenseCoversCurrentTerms {
                            SettingsHairline()
                            SettingsRow(title: "In this app") {
                                Text(LicenseTermsSummary.inAppText(
                                    acceptedVersion: settings.acceptedLegalVersion, acceptedAt: settings.acceptedLegalDate))
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.text.color)
                            }
                            .padding(.vertical, 12)
                        }
                        ForEach(terms.clauseTexts, id: \.self) { text in
                            SettingsHairline()
                            SettingsRow(title: "Note") {
                                Text(text)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.text.color)
                            }
                            .padding(.vertical, 12)
                        }
                    }
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
                Button("Get a Key…") { NSWorkspace.shared.open(LicenseLinks.requestKey) }
                    .buttonStyle(.themed)
                SettingsCaption("Opens astrealabs.com in your browser, where you can have a new key emailed to you.")
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
