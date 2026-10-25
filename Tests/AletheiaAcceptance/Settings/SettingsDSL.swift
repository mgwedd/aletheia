@testable import Aletheia
import AppKit
import Foundation
import XCTest

// MARK: - Fakes

/// A network helper that reports a fixed run of progress and writes nothing.
private final class ProgressHelperFake: NetworkHelping, @unchecked Sendable {
    let steps: [Double]
    init(steps: [Double]) { self.steps = steps }
    func fetchAppcast() async throws -> Data { Data() }
    func fetchRevocations() async throws -> Data { Data() }
    func download(
        _ asset: AssetID, expectedSHA256: String, to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        for step in steps { onProgress(step) }
    }
}

// MARK: - Subjects

/// The panes Settings lists in its sidebar.
struct SettingsSidebarList {
    let titles: [String]
}

/// The choices on a fresh install.
struct SettingsDefaults {
    let autoTranscribe: Bool
    let keepRawAudio: Bool
    let notificationNames: Bool
    let autoCheckForUpdates: Bool
}

/// A model download seen from the progress bar.
struct DownloadProgress {
    let fractions: [Double]
    let finished: Double
    let stillDownloading: Bool
}

/// The engine picker and what backs it.
struct EnginePicker {
    let options: [AssistantBackend]
    let appleIntelligenceBlocked: Bool
}

/// What shows about a model before it downloads.
struct ModelLicense {
    let name: String
    let url: URL
    let attribution: String?
}

/// The risk phrase list.
struct RiskPhraseList {
    let phrases: [String]
    let isDefault: Bool
}

/// The Note format pane's choices, after a relaunch.
struct NoteFormatChoices {
    let format: ProgressNoteFormat
    let verbosity: SummaryVerbosity
    let includeComments: Bool
    let includeBackground: Bool
    let formatsOffered: [ProgressNoteFormat]
    let lengthsOffered: [SummaryVerbosity]
}

/// The result of pointing the data folder somewhere.
struct FolderAttempt {
    let message: String?
    let folderAfter: URL?
    let folderBefore: URL?
}

/// A data folder moved onto this Mac.
struct FolderMove {
    let sheetShowsForSyncedFolder: Bool
    let sheetHiddenWhileLocked: Bool
    let copyMatches: Bool
    let originalStillThere: Bool
    let reboundTo: URL?
    let destination: URL
}

/// What Legal and Licenses hold.
struct LegalPane {
    let links: [URL]
    let noticeBlocks: Int
    let noticesLoaded: Bool
}

/// The appearance after a choice and a relaunch.
struct AppearanceChoice {
    let appliedName: NSAppearance.Name?
    let afterRelaunch: AppearancePreference
}

/// Light or Dark, as the Appearance control names them.
enum AppearanceMode { case light, dark }

// MARK: - Given

// MARK: - When

extension When {
    func openSettings() -> SettingsSidebarList {
        let registry = app.appModel.featureRegistry
        let offered = SettingsAvailability.encryptionOffered(
            isEnabled: false, moduleInBuild: registry.contains(id: AtRestEncryptionFeatureModule.id))
        return SettingsSidebarList(titles: SettingsPane.available(encryptionOffered: offered).map(\.title))
    }

    func lookAtDefaults() -> SettingsDefaults {
        SettingsDefaults(
            autoTranscribe: app.settings.autoTranscribeAfterRecording,
            keepRawAudio: app.settings.keepAudioRecordings,
            notificationNames: app.settings.notificationsShowPatientNames,
            autoCheckForUpdates: app.settings.autoCheckForUpdates)
    }

    func chooseAppearance(_ mode: AppearanceMode) -> AppearanceChoice {
        app.settings.appearance = mode == .light ? .light : .dark
        let applied = NSApplication.shared.appearance?.name
        app.relaunch(tier: app.tier)
        let after = app.settings.appearance
        // Leave the host app as it was found.
        app.settings.appearance = .system
        return AppearanceChoice(appliedName: applied, afterRelaunch: after)
    }

    func downloadSpeechModel() async throws -> DownloadProgress {
        let helper = ProgressHelperFake(steps: [0.25, 0.5, 1.0])
        let downloader = WhisperModelDownloader(helper: helper)
        let target = app.root.appendingPathComponent("speech-model.bin")
        try await downloader.download(app.settings.whisperModel, to: target)
        try await Task.sleep(nanoseconds: 200_000_000)
        return DownloadProgress(
            fractions: [downloader.progress], finished: downloader.progress,
            stillDownloading: downloader.isDownloading)
    }

    func lookAtEnginePicker() -> EnginePicker {
        EnginePicker(
            options: AssistantBackend.selectableOptions(
                embeddedLlamaAvailable: app.appModel.featureRegistry.contains(id: EmbeddedLlamaFeatureModule.id),
                appleIntelligenceBlocked: Integrations.appleIntelligenceBlocked),
            appleIntelligenceBlocked: Integrations.appleIntelligenceBlocked)
    }

    func pickBuiltInModels() -> [ModelLicense] {
        LlamaModel.allCases.map {
            app.settings.llamaModel = $0
            return ModelLicense(
                name: app.settings.llamaModel.licenseName, url: app.settings.llamaModel.licenseURL,
                attribution: app.settings.llamaModel.attribution)
        }
    }

    func downloadStatusLabels(atProgress values: [Double]) -> [String] {
        values.map(LlamaModelDownloader.statusLabel(forProgress:))
    }

    func addRiskPhrase(_ text: String) -> RiskPhraseList {
        app.settings.addRiskPhrase(text)
        return lookAtRiskPhrases()
    }

    func removeRiskPhrase(_ text: String) -> RiskPhraseList {
        app.settings.riskPhrases.removeAll { $0 == text }
        return lookAtRiskPhrases()
    }

    func resetRiskPhrases() -> RiskPhraseList {
        app.settings.resetRiskPhrases()
        return lookAtRiskPhrases()
    }

    func lookAtRiskPhrases() -> RiskPhraseList {
        RiskPhraseList(
            phrases: app.settings.riskPhrases,
            isDefault: app.settings.riskPhrases == LongSessionNote.defaultRiskPhrases)
    }

    func setNoteFormat(
        _ formatName: String, summaryLength lengthName: String, comments: Bool, background: Bool
    ) -> NoteFormatChoices {
        app.settings.progressNoteFormat = ProgressNoteFormat.allCases.first { $0.displayName == formatName } ?? .default
        app.settings.summaryVerbosity = SummaryVerbosity.allCases.first { $0.displayName == lengthName } ?? .default
        app.settings.includeCommentsInDrafts = comments
        app.settings.includePatientBackground = background
        app.relaunch(tier: app.tier)
        return NoteFormatChoices(
            format: app.settings.progressNoteFormat, verbosity: app.settings.summaryVerbosity,
            includeComments: app.settings.includeCommentsInDrafts,
            includeBackground: app.settings.includePatientBackground,
            formatsOffered: ProgressNoteFormat.allCases, lengthsOffered: SummaryVerbosity.allCases)
    }

    func turnOnRecordingDiagnostics() -> Bool {
        let before = app.settings.debugDiagnosticsEnabled
        app.settings.debugDiagnosticsEnabled = true
        app.relaunch(tier: app.tier)
        return !before && app.settings.debugDiagnosticsEnabled
    }

    func lookAtLegal() -> LegalPane {
        let text = ThirdPartyNotices.load()
        return LegalPane(
            links: [Legal.termsURL, Legal.privacyURL],
            noticeBlocks: text.map { ThirdPartyNotices.blocks(from: $0).count } ?? 0,
            noticesLoaded: text != nil)
    }

    /// Points the data folder at a folder; a refused folder throws before anything is saved.
    func chooseDataFolderInCloudSyncedFolder() -> FolderAttempt {
        chooseDataFolder(DataFolderPolicy.realHome
            .appendingPathComponent("Library/CloudStorage/Dropbox/Aletheia", isDirectory: true))
    }

    func chooseDataFolderInICloudDrive() -> FolderAttempt {
        chooseDataFolder(DataFolderPolicy.realHome
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Aletheia", isDirectory: true))
    }

    private func chooseDataFolder(_ url: URL) -> FolderAttempt {
        let before = app.settings.dataRootURL
        var message: String?
        do { try app.settings.setDataRoot(url) } catch { message = error.localizedDescription }
        return FolderAttempt(message: message, folderAfter: app.settings.dataRootURL, folderBefore: before)
    }

    /// Copies a synced folder to a local one the way the move sheet does.
    func moveSyncedFolderToThisMac() throws -> FolderMove {
        let synced = DataFolderPolicy.realHome
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Aletheia", isDirectory: true)
        let source = app.root.appendingPathComponent("synced-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("p1"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("p1/patient.json"))
        let destination = app.root.appendingPathComponent("local", isDirectory: true).appendingPathComponent("Aletheia Data")
        var rebound: URL?
        try DataFolderMove.copyAndRebind(source: source, destination: destination) { rebound = $0 }
        return FolderMove(
            sheetShowsForSyncedFolder: DataFolderPolicy.verdict(for: synced) != .ok
                && DataFolderPolicy.presentsMoveSheet(requested: true, appLocked: false),
            sheetHiddenWhileLocked: !DataFolderPolicy.presentsMoveSheet(requested: true, appLocked: true),
            copyMatches: (try? DataFolderMove.verifyCopy(source, destination)) == true,
            originalStillThere: FileManager.default.fileExists(atPath: source.path),
            reboundTo: rebound, destination: destination)
    }
}

// MARK: - Then

extension Then where Subject == SettingsSidebarList {
    func listsPanes(_ titles: [String]) { expectEqual(subject.titles, titles, "the Settings panes") }
}

extension Then where Subject == SettingsDefaults {
    func areTheFreshInstallDefaults() {
        expect(subject.autoTranscribe, "automatic transcription should be on")
        expect(!subject.keepRawAudio, "keeping raw audio should be off")
        expect(!subject.notificationNames, "names in notifications should be off")
    }
}

extension Then where Subject == AppearanceChoice {
    func appliedAtOnce(_ mode: AppearanceMode) {
        expectEqual(subject.appliedName, mode == .light ? .aqua : .darkAqua, "the app's appearance")
    }
    func staysAfterRelaunch(_ mode: AppearanceMode) {
        expectEqual(subject.afterRelaunch, mode == .light ? .light : .dark, "the appearance after relaunch")
    }
}

extension Then where Subject == DownloadProgress {
    func barFilled() {
        expectEqual(subject.finished, 1.0, "the final progress")
        expect(!subject.stillDownloading, "the download should be finished")
    }
}

extension Then where Subject == EnginePicker {
    func offersOnly(_ names: [String]) { expectEqual(subject.options.map(\.displayName), names, "the engine options") }
    func keepsAppleIntelligenceOff() {
        expect(subject.appleIntelligenceBlocked, "Apple Intelligence should stay off")
        expect(!subject.options.contains(.appleIntelligence), "Apple Intelligence should not be offered")
    }
}

extension Then where Subject == [ModelLicense] {
    func eachShowsALicenseLink() {
        expect(!subject.isEmpty, "there should be built-in models to pick")
        for license in subject {
            expect(!license.name.isEmpty, "a model has no license name")
            expectEqual(license.url.scheme, "https", "the scheme of \(license.name)'s license link")
        }
    }
}

extension Then where Subject == [String] {
    func read(_ labels: [String]) {
        expect(
            zip(subject, labels).allSatisfy { $0.hasPrefix($1) } && subject.count == labels.count,
            "expected status lines starting \(labels), found \(subject)")
    }
}

extension Then where Subject == RiskPhraseList {
    func lists(_ phrase: String) { expect(subject.phrases.contains(phrase), "\"\(phrase)\" should be listed") }
    func doesNotList(_ phrase: String) { expect(!subject.phrases.contains(phrase), "\"\(phrase)\" should be gone") }
    func isTheDefaultList() { expect(subject.isDefault, "the list should be the built-in one") }
    func isCustomised() { expect(!subject.isDefault, "the list should differ from the built-in one") }
}

extension Then where Subject == NoteFormatChoices {
    func keeps(_ formatName: String, summaryLength lengthName: String, comments: Bool, background: Bool) {
        expectEqual(subject.format.displayName, formatName, "the default format")
        expectEqual(subject.verbosity.displayName, lengthName, "the summary length")
        expectEqual(subject.includeComments, comments, "comments in drafts")
        expectEqual(subject.includeBackground, background, "patient background in drafts")
        expect(subject.formatsOffered.count > 1 && subject.lengthsOffered.count > 1, "there should be choices")
    }
}

extension Then where Subject == Bool {
    func wasTurnedOn(_ what: String) { expect(subject, "\(what) should turn on and stay on") }
}

extension Then where Subject == LegalPane {
    func holdsTermsAndNotices() {
        expectEqual(subject.links.count, 2, "terms links")
        expect(subject.noticesLoaded, "the third-party notices should be in the build")
        expect(subject.noticeBlocks > 0, "the third-party notices should have content")
    }
}

extension Then where Subject == FolderAttempt {
    func wasRefused(saying text: String) {
        expect(subject.message?.contains(text) == true, "expected a message with \"\(text)\", found \(subject.message ?? "none")")
        expectEqual(subject.folderAfter, subject.folderBefore, "the data folder after the refusal")
    }
}

extension Then where Subject == FolderMove {
    func offersToCopyAndVerify() {
        expect(subject.sheetShowsForSyncedFolder, "the Move data to this Mac sheet should show for a synced folder")
        expect(subject.sheetHiddenWhileLocked, "the sheet should wait behind the app lock")
        expect(subject.copyMatches, "the copy should verify against the original")
        expectEqual(subject.reboundTo, subject.destination, "the folder Aletheia now uses")
        expect(subject.originalStillThere, "the original should stay until you delete it")
    }
}
