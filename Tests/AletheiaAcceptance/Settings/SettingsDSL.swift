@testable import Aletheia
import AppKit
import Foundation
import XCTest

// MARK: - Fakes

/// A network helper that reports a fixed run of progress, then leaves a file at the destination.
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
        try Data("model".utf8).write(to: destination)
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
    let midway: ModelCardPresentation
    let finished: ModelCardPresentation
    let finishedFraction: Double
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
struct DataFolderRow {
    let chosen: URL
    let shownPath: String
    let button: String
    let folderAfterRelaunch: URL?
}

/// Reset to Defaults and Clear All, before and after the yes.
struct RiskPhraseConfirmation {
    let asked: RiskPhraseEditor.Confirmation?
    let listWhileAsking: [String]
    let listAfterNo: [String]
    let listAfterYes: [String]
}

struct RecordingPane {
    let readoutOff: [String]?
    let readoutOn: [String]?
}

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
    let choices: [String]
    let originalGoneAfterDelete: Bool
}

/// What Legal and Licenses hold.
struct LegalPane {
    let items: [String]
    let links: [URL]
    let noticeBlocks: Int
    let noticesLoaded: Bool
}

/// The built-in models offered for a Mac of a given memory size.
/// The built-in model settings has selected, and what else it offers.
struct SelectedBuiltInModel {
    let shortName: String
    let offered: [String]
    /// What is selected the launch after, once the weights' check no longer decides.
    let shortNameNextLaunch: String
}

struct OfferedBuiltInModels {
    let shortNames: [String]
    let medGemmaShortName: String
}

/// License terms for the medical models.
struct MedicalModelLicenses {
    let medGemma4BLicense: String
    let medGemma27BLicense: String
    let apertus8BLicense: String
    let allUseHTTPS: Bool
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
        app.settings.appearance = .default
        return AppearanceChoice(appliedName: applied, afterRelaunch: after)
    }

    /// Downloads the speech model and returns the card as it reads mid-way and when done.
    func downloadSpeechModel() async throws -> DownloadProgress {
        let helper = ProgressHelperFake(steps: [0.25, 0.5, 1.0])
        let downloader = WhisperModelDownloader(helper: helper)
        let model = app.settings.whisperModel
        let target = app.root.appendingPathComponent("speech-model.bin")
        let midway = ModelCardPresentation(
            installed: false, isDownloading: true, progress: 0.5, sizeMB: model.approximateSizeMB)
        try await downloader.download(model, to: target)
        // Progress reaches the main queue a beat after the download returns.
        try await eventually("the speech model bar to read 100%") { downloader.progress == 1.0 }
        let finished = ModelCardPresentation(
            installed: FileManager.default.fileExists(atPath: target.path),
            isDownloading: downloader.isDownloading, progress: downloader.progress,
            sizeMB: model.approximateSizeMB)
        return DownloadProgress(midway: midway, finished: finished, finishedFraction: downloader.progress)
    }


    /// The data folder row, and the folder in use after the app is quit and reopened.
    func chooseDataFolderThenRelaunch() throws -> DataFolderRow {
        let chosen = app.root.appendingPathComponent("chosen-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try app.settings.setDataRoot(chosen)
        let shown = DataFolderDisplay.text(for: app.settings.dataRootURL)
        app.relaunch(tier: app.tier)
        return DataFolderRow(
            chosen: chosen, shownPath: shown, button: DataFolderDisplay.chooseButton,
            folderAfterRelaunch: app.settings.dataRootURL)
    }

    /// The cards for the speech model and for each built-in model, before anything downloads.
    func lookAtModelCards() -> [ModelCardPresentation] {
        let speech = ModelCardPresentation(
            installed: false, isDownloading: false, progress: 0, sizeMB: app.settings.whisperModel.approximateSizeMB)
        return [speech] + LlamaModel.allCases.map {
            ModelCardPresentation(installed: false, isDownloading: false, progress: 0, sizeMB: $0.approximateSizeMB)
        }
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

    func askToResetRiskPhrases() -> RiskPhraseConfirmation {
        app.settings.addRiskPhrase("custom phrase")
        var editor = RiskPhraseEditor()
        editor.askToReset()
        let asked = editor.pending
        let whileAsking = app.settings.riskPhrases
        editor.cancel()
        let afterNo = app.settings.riskPhrases
        RiskPhraseEditor.apply(.resetToDefaults, to: app.settings)
        return RiskPhraseConfirmation(
            asked: asked, listWhileAsking: whileAsking, listAfterNo: afterNo, listAfterYes: app.settings.riskPhrases)
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

    /// The recording pane with the setting off, then on: the readout rows it shows each time.
    func openRecordingPane() -> RecordingPane {
        let sample = CallAudioDiagnostics(
            preflightGranted: true, currentBuild: "acceptance", confirmedBuild: nil, attemptedThisLaunch: false,
            workedThisLaunch: false, lastStart: .notTried, streamRunning: false, streamDisrupted: false,
            buffersReceived: 0, bytesWritten: nil, disruptions: 0, firstFailure: nil)
        app.settings.debugDiagnosticsEnabled = false
        let off = RecordingDiagnostics.readout(enabled: app.settings.debugDiagnosticsEnabled) { sample }
        app.settings.debugDiagnosticsEnabled = true
        let on = RecordingDiagnostics.readout(enabled: app.settings.debugDiagnosticsEnabled) { sample }
        return RecordingPane(readoutOff: off?.map(\.label), readoutOn: on?.map(\.label))
    }

    func lookAtLegal() -> LegalPane {
        let text = ThirdPartyNotices.load()
        return LegalPane(
            items: SettingsLegalItem.all.map(\.id),
            links: Legal.Document.allCases.map(\.url),
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
        let stillThere = FileManager.default.fileExists(atPath: source.path)
        let copyMatches = (try? DataFolderMove.verifyCopy(source, destination)) == true
        try DataFolderMove.deleteOriginal(source)
        let goneAfterDelete = !FileManager.default.fileExists(atPath: source.path)
        return FolderMove(
            sheetShowsForSyncedFolder: DataFolderPolicy.verdict(for: synced) != .ok
                && DataFolderPolicy.presentsMoveSheet(requested: true, appLocked: false),
            sheetHiddenWhileLocked: !DataFolderPolicy.presentsMoveSheet(requested: true, appLocked: true),
            copyMatches: copyMatches,
            originalStillThere: stillThere,
            reboundTo: rebound, destination: destination,
            choices: DataFolderMoveChoice.allCases.map(\.title),
            originalGoneAfterDelete: goneAfterDelete)
    }

    func lookAtBuiltInModels(onMacWithMemoryGB memoryGB: Int) -> OfferedBuiltInModels {
        let hardware = HardwareCapabilities(
            isAppleSilicon: true, physicalMemoryGB: memoryGB, coreCount: 8, chipDescription: "Apple M-Test")
        let offered = LlamaModel.offered(for: hardware)
        let recommendation = ModelAdvisor.recommend(for: hardware)
        return OfferedBuiltInModels(
            shortNames: offered.map(\.shortName),
            medGemmaShortName: recommendation.medGemmaModel.shortName)
    }

    /// Opens settings for the first time after an update, on a Mac with this
    /// much memory, with these models (by short name) downloaded and no model
    /// ever chosen.
    func openAfterUpdating(onMacWithMemoryGB memoryGB: Int, downloaded: [String]) -> SelectedBuiltInModel {
        let hardware = HardwareCapabilities(
            isAppleSilicon: true, physicalMemoryGB: memoryGB, coreCount: 8, chipDescription: "Apple M-Test")
        let suite = "acceptance.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, hardware: hardware) { downloaded.contains($0.shortName) }
        let reopened = AppSettings(defaults: defaults, hardware: hardware) { _ in false }
        return SelectedBuiltInModel(
            shortName: settings.llamaModel.shortName,
            offered: LlamaModel.offered(for: hardware, including: settings.llamaModel).map(\.shortName),
            shortNameNextLaunch: reopened.llamaModel.shortName)
    }

    func lookAtMedicalModelLicenses() -> MedicalModelLicenses {
        let models: [LlamaModel] = [.medgemma15_4b, .medgemma_27b, .apertus8b_meditronFO]
        let https = models.allSatisfy {
            $0.licenseURL.scheme == "https" && ($0.acceptableUseURL.map { $0.scheme == "https" } ?? true)
        }
        return MedicalModelLicenses(
            medGemma4BLicense: LlamaModel.medgemma15_4b.licenseName,
            medGemma27BLicense: LlamaModel.medgemma_27b.licenseName,
            apertus8BLicense: LlamaModel.apertus8b_meditronFO.licenseName,
            allUseHTTPS: https)
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
        expectEqual(subject.midway.rows.contains(.progress(fraction: 0.5)), true, "a percent bar while downloading")
        expectEqual(subject.finishedFraction, 1.0, "the final progress")
        expectEqual(ModelCardPresentation.percentText(subject.finishedFraction), "100%", "the bar's caption when full")
        expectEqual(subject.finished.chip, "Installed", "the card's label once downloaded")
        expect(subject.finished.rows.contains(.installed), "the Installed row should replace the bar")
    }
}

extension Then where Subject == EnginePicker {
    func offersOnly(_ names: [String]) { expectEqual(subject.options.map(\.displayName), names, "the engine options") }
    func keepsAppleIntelligenceOff() {
        expect(subject.appleIntelligenceBlocked, "Apple Intelligence should stay off")
        expect(!subject.options.contains(.appleIntelligence), "Apple Intelligence should not be offered")
    }
    func isHidden() {
        expect(!AssistantBackend.offersEngineChoice(subject.options), "the Engine menu should be hidden with only one engine")
    }
}

extension Then where Subject == [ModelCardPresentation] {
    func showTheLicenseLinkBeforeTheDownload() {
        for card in subject {
            let link = card.rows.firstIndex(of: .licenseLink)
            let download = card.rows.firstIndex { if case .downloadPrompt = $0 { return true } else { return false } }
            expect(link != nil && download != nil, "a card should have a license link and a download: \(card.rows)")
            if let link, let download { expect(link < download, "the license link should sit above the download: \(card.rows)") }
        }
    }
}

extension Then where Subject == DataFolderRow {
    func showsPathAndChoose() {
        expectEqual(subject.shownPath, subject.chosen.path, "the path in the row")
        expectEqual(subject.button, "Choose…", "the button next to the path")
    }

    func isStillInUseAfterRelaunch() {
        expectEqual(
            subject.folderAfterRelaunch?.resolvingSymlinksInPath().path,
            subject.chosen.resolvingSymlinksInPath().path, "the data folder after relaunch")
    }
}

extension Then where Subject == RiskPhraseConfirmation {
    func asksBeforeReplacingTheList() {
        expectEqual(subject.asked, .resetToDefaults, "what Reset to Defaults asks")
        expect(subject.listWhileAsking.contains("custom phrase"), "the list should not change while asking")
        expect(subject.listAfterNo.contains("custom phrase"), "saying no should keep the list")
        expectEqual(subject.listAfterYes, LongSessionNote.defaultRiskPhrases, "the list after saying yes")
    }
}

extension Then where Subject == RecordingPane {
    func gainsADiagnosticsReadout() {
        expect(subject.readoutOff == nil, "the recording pane should have no readout while the setting is off")
        expect(subject.readoutOn?.contains("Preflight granted") == true, "the readout should show the call-audio state: \(subject.readoutOn ?? [])")
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
        expectEqual(subject.items, ["Terms of Service", "Privacy Policy", "Consent Guide…"], "what the Legal card holds")
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
        expectEqual(subject.choices, ["Keep original for now", "Delete original folder…"], "the choices after the copy")
        expect(subject.originalGoneAfterDelete, "choosing Delete should remove the original")
    }
}

extension Then where Subject == OfferedBuiltInModels {
    func includesModel(_ name: String) {
        expect(subject.shortNames.contains(name), "\(name) should be offered: \(subject.shortNames)")
    }

    func offersMedicalModels(_ medGemma: String) {
        expect(subject.shortNames.contains(medGemma), "\(medGemma) should be offered: \(subject.shortNames)")
        expectEqual(subject.medGemmaShortName, medGemma, "the MedGemma size chosen for this Mac")
        expect(!subject.shortNames.contains("MedLlama 2 7B"), "the 4K model should not be offered")
    }
}

extension Then where Subject == MedicalModelLicenses {
    func usesTerms(medGemmaTerms: String) {
        expectEqual(subject.medGemma4BLicense, medGemmaTerms, "MedGemma 1.5 4B's license")
        expectEqual(subject.medGemma27BLicense, medGemmaTerms, "MedGemma 27B's license")
        expectEqual(subject.apertus8BLicense, "Apache License 2.0", "Apertus 8B MeditronFO's license")
        expect(subject.allUseHTTPS, "every medical model's license and acceptable-use link should use https")
    }
}

extension Then where Subject == SelectedBuiltInModel {
    func keeps(_ name: String) {
        expectEqual(subject.shortName, name, "the selected built-in model")
        expectEqual(subject.shortNameNextLaunch, name, "the selected built-in model, next launch")
    }

    func stillOffers(_ name: String) {
        expect(subject.offered.contains(name), "\(name) should be offered: \(subject.offered)")
    }

    func selects(_ name: String) { expectEqual(subject.shortName, name, "the selected built-in model") }
}
