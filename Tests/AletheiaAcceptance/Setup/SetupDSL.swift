@testable import Aletheia
import AVFoundation
import Foundation
import XCTest

// MARK: - Subjects

/// The setup checklist as the sheet lists it, top to bottom.
struct SetupChecklist {
    let items: [SetupItem]

    var progress: Setup.Progress { Setup.progress(items) }
    var counter: String { progress.label }

    func item(_ kind: ToolHealthCheck.Kind) -> SetupItem? { items.first { $0.id == kind } }
}

/// One checklist row's state, from a classified check.
struct SetupRowState {
    let item: SetupItem
}

/// The "Protect your data" step for the current folder.
struct EncryptionStep {
    let moduleInBuild: Bool
    let withoutFolder: FirstRunEncryptionStep.Offer
    let withFolder: FirstRunEncryptionStep.Offer
    /// Whether Finish setup is available with a folder and the terms, encryption untouched.
    let finishWithFolderOnly: Bool
}

/// The Data folder step of the setup sheet, as it reads.
struct DataFolderStep {
    let rule: String
    let recommendation: String
    let chosen: String?
}

/// Finish setup, as the sheet's footer shows it.
struct FinishButton {
    let enabled: Bool
    let hint: String
}

struct MicrophoneClick {
    let prompts: Int
    let rowAfter: SetupRowState
}

struct CallAudioClick {
    let openedPanes: [String]
    let looks: Int
    let rowAfter: SetupRowState
}

/// How a checklist row reads to the user.
enum RowTone { case done, needsAttention, problem }

/// What macOS says about microphone access.
enum MicrophoneAccess { case notAskedYet, denied, allowed }

/// The buttons the checklist offers, by what they say.
// MARK: - Given

extension Given {
    func noDataFolderChosen() { app.settings.dataRootURL = nil }
    func dataFolderChosen() { app.settings.dataRootURL = app.root }
}

/// The macOS side of the checklist buttons, answering as scripted.
@MainActor
final class ScriptedSystem: SetupSystem {
    var folder: URL?
    var microphoneAnswer = true
    var callAudioAnswer = false
    /// The look at which System Settings has the grant, counting from 1.
    var grantedAtLook = Int.max
    private(set) var looks = 0
    private(set) var microphonePrompts = 0
    private(set) var openedPanes: [String] = []

    func chooseFolder() -> URL? { folder }
    func requestMicrophone() async -> Bool { microphonePrompts += 1; return microphoneAnswer }
    func openMicrophoneSettings() { openedPanes.append("microphone") }
    func requestCallAudio() async -> Bool { callAudioAnswer }
    func callAudioGranted() -> Bool { looks += 1; return looks >= grantedAtLook }
    func openCallAudioSettings() { openedPanes.append("call audio") }
    func armCallAudioProbe() {}
    func confirmCallAudioGrant() {}
}

// MARK: - When

extension When {
    func openFirstRunGate() -> FirstRunGate { FirstRunGate(settings: app.settings) }

    /// Asks the sheet to close (Escape, a click outside) and says whether it is still up.
    func sheetStaysUpAfterTryingToClose() -> Bool {
        let presentation = FirstRunGate.presentation(settings: app.settings)
        presentation.wrappedValue = false
        return presentation.wrappedValue
    }

    func finishButton() -> FinishButton {
        let hasFolder = app.settings.dataRootURL != nil
        let agreed = app.settings.hasAcceptedCurrentLegal
        return FinishButton(
            enabled: FirstRunFinish.isEnabled(hasDataFolder: hasFolder, agreedToTerms: agreed),
            hint: FirstRunFinish.hint(hasDataFolder: hasFolder, agreedToTerms: agreed))
    }

    func chooseFolder(_ folder: URL?) async throws {
        let system = ScriptedSystem()
        system.folder = folder
        let runner = SetupActionRunner(system: system, settings: app.settings, rebuildStore: { self.app.appModel.rebuildStore() })
        _ = try await runner.perform(.chooseFolder)
    }

    /// Clicks Allow Microphone and answers the macOS prompt; returns the row as it reads afterwards.
    func allowMicrophone(answer: MicrophoneAccess) async throws -> MicrophoneClick {
        let system = ScriptedSystem()
        system.microphoneAnswer = answer == .allowed
        let runner = SetupActionRunner(system: system, settings: app.settings, rebuildStore: {})
        _ = try await runner.perform(.requestMicrophone)
        return MicrophoneClick(prompts: system.microphonePrompts, rowAfter: microphoneRow(answer))
    }

    /// Clicks Allow on call audio, declines the prompt, grants in System Settings on the nth look.
    func allowCallAudio(grantedInSettingsAtLook look: Int) async throws -> CallAudioClick {
        let system = ScriptedSystem()
        system.grantedAtLook = look
        let runner = SetupActionRunner(
            system: system, settings: app.settings, rebuildStore: {}, pollInterval: 0, maxPolls: 10)
        _ = try await runner.perform(.requestScreenRecording)
        return CallAudioClick(
            openedPanes: system.openedPanes, looks: system.looks,
            rowAfter: callAudioRow(granted: system.looks >= look))
    }

    func readConsentGuide() -> [ConsentGuideContent.Section] { ConsentGuideContent.sections }
    var consentSampleClause: String { ConsentGuideContent.sampleClause }

    /// Runs the same checks the sheet runs, for the services this build ships.
    func readChecklist() async -> SetupChecklist {
        let checks = await ToolHealth.runAllChecks(
            settings: app.settings,
            backend: .automatic,
            assistant: UnavailableAssistant(),
            authoritative: false,
            includeScheduling: app.appModel.featureRegistry.contains(id: EventKitSchedulingFeatureModule.id))
        return SetupChecklist(items: Setup.items(from: checks))
    }

    func readRow(_ check: ToolHealthCheck) -> SetupRowState {
        SetupRowState(item: Setup.items(from: [check])[0])
    }

    func microphoneRow(_ access: MicrophoneAccess) -> SetupRowState {
        let status: AVAuthorizationStatus
        switch access {
        case .notAskedYet: status = .notDetermined
        case .denied: status = .denied
        case .allowed: status = .authorized
        }
        return readRow(ToolHealth.classifyMicrophone(status))
    }

    func callAudioRow(granted: Bool) -> SetupRowState {
        readRow(ToolHealth.classifyScreenRecording(granted: granted))
    }

    func termsRow() -> SetupRowState { readRow(ToolHealth.termsAndPrivacyCheck(settings: app.settings)) }
    func dataFolderRow() -> SetupRowState { readRow(ToolHealth.dataFolderCheck(settings: app.settings)) }

    func speechModelRow(installed: Bool) -> SetupRowState {
        let model = app.settings.whisperModel
        return readRow(ToolHealth.classifyWhisperModel(
            exists: installed, modelDisplayName: model.displayName, sizeMB: model.approximateSizeMB))
    }

    func aiRow(installed: Bool) -> SetupRowState {
        let model = app.settings.llamaModel
        return readRow(ToolHealth.classifyBuiltInModel(
            installed: installed, modelName: model.shortName, sizeMB: model.approximateSizeMB))
    }

    func agreeToTerms() { app.settings.recordLegalAcceptance(at: app.clock.now) }

    func finishSetup() { FirstRunGate.finish(settings: app.settings, license: nil) }

    /// The setup sheet comes on screen.
    func setupSheetAppears() { FirstRunGate.sheetAppeared(settings: app.settings) }

    func readDataFolderStep() -> DataFolderStep {
        DataFolderStep(
            rule: FirstRunDataFolder.rule,
            recommendation: FirstRunDataFolder.recommendation,
            chosen: app.settings.dataRootURL.map(FirstRunDataFolder.chosen))
    }

    /// The terms moved on since the last acceptance: what was accepted is now an older version.
    func openBuildWithNewerTerms() {
        app.settings.recordLegalAcceptance(version: "2000-01-01", at: app.clock.now)
        app.relaunch(tier: app.tier)
    }

    func quitAndReopen() { app.relaunch(tier: app.tier) }

    /// A call-audio grant confirmed in an earlier moment is seen straight away.
    func recheckCallAudioAfterGrant() async -> SetupRowState {
        let suite = "aletheia-acceptance-grant-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CallAudioGrantStore(defaults: defaults, build: "acceptance")
        store.confirm()
        return readRow(await ToolHealth.screenRecordingCheck(authoritative: false, grantStore: store))
    }

    func lookAtEncryptionStep() -> EncryptionStep {
        EncryptionStep(
            moduleInBuild: app.appModel.featureRegistry.contains(id: AtRestEncryptionFeatureModule.id),
            withoutFolder: FirstRunEncryptionStep(hasDataFolder: false, encryptionOn: false).offer,
            withFolder: FirstRunEncryptionStep(hasDataFolder: true, encryptionOn: false).offer,
            finishWithFolderOnly: FirstRunFinish.isEnabled(hasDataFolder: true, agreedToTerms: true))
    }

    var termsLinks: [URL] { Legal.Document.allCases.map(\.url) }
    var dataFolderPath: String { app.root.path }
    var receiptExists: Bool { app.probe.files().contains("legal-acceptance.log") }
}

// MARK: - Then

extension Then where Subject == FirstRunGate {
    func sheetShows() { expect(subject.sheetShows, "the Set up Aletheia sheet should be up on a first launch") }
    func sheetIsGone() { expect(!subject.sheetShows, "the Set up Aletheia sheet should not appear again") }
}

extension Then where Subject == SetupChecklist {
    func listsRows(inOrder titles: [String]) {
        expectEqual(Array(subject.items.map(\.title).prefix(titles.count)), titles, "the first rows")
    }

    func countsDone() {
        let done = subject.items.filter { $0.status == .ok }.count
        expectEqual(subject.progress.done, done, "done rows")
        expectEqual(subject.progress.total, subject.items.count, "total rows")
        expectEqual(subject.counter, "\(done) of \(subject.items.count) done", "the counter")
    }
}

extension Then where Subject == [URL] {
    func areTermsAndPrivacyOnGitHub() {
        expectEqual(subject.count, 2, "number of links")
        for url in subject {
            expectEqual(url.host, "github.com", "the host of \(url)")
            expectEqual(url.scheme, "https", "the scheme of \(url)")
        }
        expect(subject.first?.lastPathComponent == "TERMS.md", "the first link should be the Terms of Service")
        expect(subject.last?.lastPathComponent == "PRIVACY.md", "the second link should be the Privacy Policy")
    }
}

extension Then where Subject == SetupRowState {
    func isDone() {
        expectEqual(subject.item.status, .ok, "status of \(subject.item.title)")
        expect(subject.item.action == nil, "\(subject.item.title) should have no button once done")
    }

    func needsButton(_ label: String, row tone: RowTone) {
        let item = subject.item
        let actual: RowTone = item.status == .ok ? .done : (item.status == .warning ? .needsAttention : .problem)
        expectEqual(actual, tone, "how \(item.title) reads")
        expectEqual(item.action?.label, label, "the button on \(item.title)")
    }

    func offersDownloadWithSize() {
        expect(subject.item.detail.contains(" MB"), "\(subject.item.title) should give the download size: \(subject.item.detail)")
    }

    func detailMentions(_ text: String) {
        expect(subject.item.detail.contains(text), "detail \"\(subject.item.detail)\" should mention \(text)")
    }

    func isReadyRow() {
        expectEqual(subject.item.status, .ok, "status of \(subject.item.title)")
        expect(subject.item.detail.contains("ready"), "detail should say ready: \(subject.item.detail)")
    }
}

extension Then where Subject == EncryptionStep {
    func isRecommendedOnceFolderChosen() {
        expect(subject.moduleInBuild, "the Protect your data step should be in this build")
        expectEqual(subject.withoutFolder, .chooseFolderFirst, "the step before a folder is chosen")
        expect(
            subject.withFolder == .recommended(button: Copy.setUpEncryptionButton),
            "encryption should be recommended with a \(Copy.setUpEncryptionButton) button once a folder is chosen, found \(subject.withFolder)")
    }

    func doesNotBlockFinish() {
        expect(subject.finishWithFolderOnly, "Finish setup should enable without setting up encryption")
    }
}

extension Then where Subject == DataFolderStep {
    func recommendsTheStandardLocationOnThisMac() {
        expect(subject.recommendation.contains("standard location"), "the step should recommend the standard location: \(subject.recommendation)")
        expect(subject.recommendation.contains("on this Mac"), "the recommendation should say it is on this Mac: \(subject.recommendation)")
    }

    func saysWhereOtherFoldersMayBe() {
        for place in ["on this Mac", "iCloud Drive", "Dropbox", "Google Drive", "OneDrive", "Box", "network drive", "encrypted"] {
            expect(subject.rule.contains(place), "the step should mention \(place): \(subject.rule)")
        }
    }

    func saysRecordsWillBeKept(in path: String) {
        expect(subject.chosen?.contains(path) == true, "the step should say records will be kept in \(path), found \(subject.chosen ?? "nothing")")
    }
}

extension Then where Subject == FinishButton {
    func isDisabled() { expect(!subject.enabled, "Finish setup should be disabled: \(subject.hint)") }
    func isEnabled() { expect(subject.enabled, "Finish setup should be enabled: \(subject.hint)") }
    func asksFor(_ text: String) { expect(subject.hint.contains(text), "the hint \"\(subject.hint)\" should ask for \(text)") }
}

extension Then where Subject == [ConsentGuideContent.Section] {
    func areNumbered() {
        expect(!subject.isEmpty, "the consent guide should have sections")
        for (index, section) in subject.enumerated() {
            expect(section.title.hasPrefix("\(index + 1)."), "section \(index + 1) should be numbered: \(section.title)")
        }
    }
}

extension Then where Subject == String {
    func isASampleConsentClause() {
        expect(subject.count > 40, "the sample consent clause should be a real clause: \(subject)")
    }
}

extension Then where Subject == MicrophoneClick {
    func asksMacOS() { expectEqual(subject.prompts, 1, "microphone prompts") }
    func leavesRow(_ tone: RowTone, button: String) {
        Then<SetupRowState>(subject: subject.rowAfter, check: check, file: file, line: line)
            .needsButton(button, row: tone)
    }
}

extension Then where Subject == CallAudioClick {
    func sendsYouToSystemSettings() { expectEqual(subject.openedPanes, ["call audio"], "settings panes opened") }
    func turnsDoneWithoutRestart() {
        Then<SetupRowState>(subject: subject.rowAfter, check: check, file: file, line: line).isDone()
    }
}

extension Then where Subject == Bool {
    func isTrue(_ what: String) { expect(subject, what) }
}
