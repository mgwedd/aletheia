import Foundation

/// How the data folder row in General reads.
enum DataFolderDisplay {
    static let chooseButton = "Choose…"
    static func text(for folder: URL?) -> String { folder?.path ?? "Not chosen yet" }
}

/// What the General pane's Legal card holds, left to right.
enum SettingsLegalItem: Equatable, Identifiable {
    case document(Legal.Document)
    case consentGuide

    var id: String {
        switch self {
        case .document(let document): return document.title
        case .consentGuide: return Self.consentGuideTitle
        }
    }

    static let consentGuideTitle = "Consent Guide…"
    static let all: [SettingsLegalItem] = Legal.Document.allCases.map { .document($0) } + [.consentGuide]
}

/// The rows of the Software update card.
enum SoftwareUpdateRow: CaseIterable {
    case version, automaticChecks, checkNow

    var title: String {
        switch self {
        case .version: return "Current version"
        case .automaticChecks: return "Check for updates automatically"
        case .checkNow: return "Check for updates"
        }
    }
}

/// A risk-phrase change that waits for a yes before it replaces the list.
struct RiskPhraseEditor {
    enum Confirmation: Equatable {
        case clearAll, resetToDefaults

        var title: String { self == .clearAll ? "Clear all risk phrases?" : "Reset risk phrases?" }
        var confirmButton: String { self == .clearAll ? "Clear All" : "Reset to Defaults" }
        var message: String {
            self == .clearAll
                ? "No lines will be prioritised for risk in long sessions until you add your own."
                : "Your list is replaced by the built-in one."
        }
    }

    private(set) var pending: Confirmation?

    mutating func askToClearAll() { pending = .clearAll }
    mutating func askToReset() { pending = .resetToDefaults }
    mutating func cancel() { pending = nil }

    @MainActor
    static func apply(_ confirmation: Confirmation, to settings: AppSettings) {
        switch confirmation {
        case .clearAll: settings.riskPhrases = []
        case .resetToDefaults: settings.resetRiskPhrases()
        }
    }
}

/// What Settings > General > "Show recording diagnostics" adds to the recording screen.
enum RecordingDiagnostics {
    /// The readout rows (permission and stream state only), or nil when the setting is off.
    static func readout(enabled: Bool, current: () -> CallAudioDiagnostics) -> [(label: String, value: String)]? {
        enabled ? current().rows : nil
    }
}

/// The two ways out of the Move data to this Mac sheet once the copy is verified.
enum DataFolderMoveChoice: CaseIterable {
    case keepOriginal, deleteOriginal

    var title: String { self == .keepOriginal ? "Keep original for now" : "Delete original folder…" }
}

/// A model card on AI and models: the chip in its header and the rows under it,
/// top to bottom. The license link sits above anything that starts a download.
struct ModelCardPresentation: Equatable {
    enum Row: Equatable {
        case picker
        case licenseLink
        case progress(fraction: Double)
        case downloadPrompt(sizeMB: Int)
        case installed
    }

    let chip: String
    let rows: [Row]

    init(installed: Bool, isDownloading: Bool, progress: Double, sizeMB: Int) {
        if isDownloading {
            chip = "Downloading"
            rows = [.picker, .licenseLink, .progress(fraction: progress)]
        } else if installed {
            chip = "Installed"
            rows = [.picker, .licenseLink, .installed]
        } else {
            chip = "Not downloaded"
            rows = [.picker, .licenseLink, .downloadPrompt(sizeMB: sizeMB)]
        }
    }

    /// "40%", as the bar's caption.
    static func percentText(_ fraction: Double) -> String { "\(Int(fraction * 100))%" }
}
