@testable import Aletheia
import AVFoundation
import Foundation
import XCTest

// MARK: - Subjects

/// The setup checklist as the sheet lists it, top to bottom.
struct SetupChecklist {
    let items: [SetupItem]

    var progress: Setup.Progress { Setup.progress(items) }
    var counter: String { "\(progress.done) of \(progress.total) done" }

    func item(_ kind: ToolHealthCheck.Kind) -> SetupItem? { items.first { $0.id == kind } }
}

/// Whether the first-run sheet would be up. Mirrors the gate in `AletheiaApp`
/// (`showFirstRun`), which is private to the view layer.
struct FirstRunGate {
    let hasDataFolder: Bool
    let hasCompletedFirstRun: Bool
    let hasAcceptedCurrentTerms: Bool

    var sheetShows: Bool { !hasDataFolder || !hasCompletedFirstRun || !hasAcceptedCurrentTerms }
}

/// One checklist row's state, from a classified check.
struct SetupRowState {
    let item: SetupItem
}

/// The "Protect your data" step for the current folder.
struct EncryptionStep {
    let moduleInBuild: Bool
    let recommendedWithoutFolder: Bool
    let recommendedWithFolder: Bool
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

// MARK: - When

extension When {
    func openFirstRunGate() -> FirstRunGate {
        FirstRunGate(
            hasDataFolder: app.settings.dataRootURL != nil,
            hasCompletedFirstRun: app.settings.hasCompletedFirstRun,
            hasAcceptedCurrentTerms: app.settings.hasAcceptedCurrentLegal)
    }

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

    func finishSetup() { app.settings.hasCompletedFirstRun = true }

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
            recommendedWithoutFolder: EncryptionOnboarding.isRecommended(dataFolderChosen: false, alreadyEnabled: false),
            recommendedWithFolder: EncryptionOnboarding.isRecommended(dataFolderChosen: true, alreadyEnabled: false))
    }

    var termsLinks: [URL] { [Legal.termsURL, Legal.privacyURL] }
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
        expect(!subject.recommendedWithoutFolder, "encryption should not be recommended before a folder is chosen")
        expect(subject.recommendedWithFolder, "encryption should be recommended once a folder is chosen")
    }
}

extension Then where Subject == Bool {
    func isTrue(_ what: String) { expect(subject, what) }
}
