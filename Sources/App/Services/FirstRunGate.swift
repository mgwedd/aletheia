import SwiftUI

/// Whether the Set up Aletheia sheet is up, and what the user can do about it.
/// The sheet covers the app until a data folder is chosen, setup is finished and
/// the current terms are accepted; it returns when the terms version changes.
struct FirstRunGate: Equatable {
    let hasDataFolder: Bool
    let hasCompletedFirstRun: Bool
    let hasAcceptedCurrentTerms: Bool

    @MainActor
    /// A license issued under the current terms counts as accepting them.
    init(settings: AppSettings, licenseCoversCurrentTerms: Bool = false) {
        hasDataFolder = settings.dataRootURL != nil
        hasCompletedFirstRun = settings.hasCompletedFirstRun
        hasAcceptedCurrentTerms = settings.hasAcceptedCurrentLegal || licenseCoversCurrentTerms
    }

    var sheetShows: Bool { !hasDataFolder || !hasCompletedFirstRun || !hasAcceptedCurrentTerms }

    /// The sheet's presentation. The user can't close it: asking to dismiss
    /// changes nothing, so it stays up until the three requirements are met.
    @MainActor
    static func presentation(settings: AppSettings, licenseCoversCurrentTerms: @escaping () -> Bool = { false }) -> Binding<Bool> {
        Binding(get: {
            FirstRunGate(settings: settings, licenseCoversCurrentTerms: licenseCoversCurrentTerms()).sheetShows
        }, set: { _ in })
    }
}

extension FirstRunGate {
    /// When the license covers the current terms, store the same local record and
    /// receipt the in-app accept writes, so a later lapse or revocation of the
    /// license doesn't bring the setup sheet back. Does nothing if already accepted.
    @MainActor
    static func recordAcceptanceCoveredByLicense(settings: AppSettings, covers: Bool, token: LicenseToken?) {
        guard covers, !settings.hasAcceptedCurrentLegal else { return }
        settings.recordLegalAcceptance(license: token)
    }
}

/// When "Finish setup" is available, and what the footer says until it is.
enum FirstRunFinish {
    static func isEnabled(hasDataFolder: Bool, agreedToTerms: Bool) -> Bool {
        hasDataFolder && agreedToTerms
    }

    static func hint(hasDataFolder: Bool, agreedToTerms: Bool) -> String {
        if !hasDataFolder { return "Choose a data folder above to continue." }
        if !agreedToTerms { return "Accept the Terms of Service and Privacy Policy to continue." }
        return "You can finish the rest of the checklist now or any time from Settings."
    }
}

/// The "Protect your data" step of first run.
struct FirstRunEncryptionStep: Equatable {
    enum Offer: Equatable {
        case alreadyOn
        /// Recommended, with a button that opens encryption setup.
        case recommended(button: String)
        case chooseFolderFirst
    }

    let offer: Offer

    init(hasDataFolder: Bool, encryptionOn: Bool) {
        if encryptionOn {
            offer = .alreadyOn
        } else if EncryptionOnboarding.isRecommended(dataFolderChosen: hasDataFolder, alreadyEnabled: encryptionOn) {
            offer = .recommended(button: "Set Up Encryption")
        } else {
            offer = .chooseFolderFirst
        }
    }
}
