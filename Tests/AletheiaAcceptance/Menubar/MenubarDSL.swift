@testable import Aletheia
import Foundation
import SwiftUI
import XCTest

// MARK: - Subjects

/// What pressing Start recording in the menu bar panel did.
struct MenuBarStart {
    let session: SessionRecord?
    let problem: String?
    let sessionsBefore: Int
    let sessionsAfter: Int
}

/// A quit-time job that has work in flight.
@MainActor
final class BusyJob: ShutdownJob {
    let work: [InterruptedWork]
    private(set) var wasShutDown = false

    init(work: [InterruptedWork]) { self.work = work }

    func interruptedWork() -> [InterruptedWork] { work }
    func shutDown() async { wasShutDown = true }
}

struct QuitOutcome {
    let report: ShutdownCoordinator.Report
    let ledger: InterruptedWorkLedger
    let job: BusyJob
}

/// The Keyboard Shortcuts window as listed.
struct ShortcutsWindow {
    let groupSizes: [Int]
}

/// The feedback page Help > Report a Bug… opens.
struct FeedbackPage {
    let url: URL
    var items: [URLQueryItem] { URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
}

/// A pointer resting on a control that has a help tip.
struct HoverRest {
    private var intent = HoverIntent()
    private let start = ContinuousClock.now
    private var deadline: HoverIntent.Deadline?

    mutating func rest() { deadline = intent.enter(at: start) }
    mutating func leave() { intent.exit() }

    func tipShows(after seconds: Double) -> Bool {
        guard let deadline else { return false }
        return intent.isDue(deadline, at: start + .milliseconds(Int(seconds * 1000)))
    }
}

// MARK: - When

extension When {
    /// The panel's Start recording for `patient`, step for step: the
    /// FileVault gate, a new session, then the recorder.
    func startFromMenuBar(_ patient: Patient, on bench: RecordingBench) async throws -> MenuBarStart {
        let model = app.appModel
        let store = try XCTUnwrap(model.store)
        let before = (try? store.listSessions(for: patient).count) ?? 0
        func result(_ session: SessionRecord?, _ problem: String?) -> MenuBarStart {
            MenuBarStart(
                session: session, problem: problem, sessionsBefore: before,
                sessionsAfter: (try? store.listSessions(for: patient).count) ?? 0)
        }
        guard !bench.recorder.isBusy else { return result(nil, nil) }
        model.refreshDiskEncryption()
        guard PHIEntryGate.allowsNewPHI(diskEncrypted: model.diskEncrypted) else {
            return result(nil, PHIEntryGate.blockedMessage)
        }
        guard let session = model.startNewSession(for: patient) else {
            return result(nil, "Couldn't create a session. Check the data folder in Settings.")
        }
        let problem = await bench.recorder.start(
            micURL: store.micRecordingURL(for: patient, session: session),
            callURL: store.callRecordingURL(for: patient, session: session),
            context: bench.context(for: patient, session: session),
            protector: model.currentProtector)
        return result(session, problem)
    }

    /// Quit while `work` is running.
    func quit(withWork work: [InterruptedWork]) async -> QuitOutcome {
        let ledger = InterruptedWorkLedger(dataRoot: app.root)
        let coordinator = ShutdownCoordinator(ledger: { ledger })
        let job = BusyJob(work: work)
        coordinator.register(job)
        let report = await coordinator.shutDown()
        return QuitOutcome(report: report, ledger: ledger, job: job)
    }

    /// The panel's patient line while recording `patient`, under the settings now.
    func menuBarPatientLabel(for patient: Patient) -> String {
        MenuBarContentPolicy.patientLabel(
            name: patient.name, showFullName: app.settings.notificationsShowPatientNames, isLocked: false)
    }

    /// The menu bar icon's symbol under the recorder's state now.
    func menuBarIcon(on bench: RecordingBench) -> String {
        MenuBarPanel.iconSymbol(isRecording: bench.recorder.isRecording, isPaused: bench.recorder.isPaused)
    }

    /// Pause from the panel's Pause button.
    func pauseFromMenuBar(on bench: RecordingBench) { bench.recorder.pause() }

    /// What the panel shows when opened, with the app locked or not.
    func openMenuBarPanel(on bench: RecordingBench, locked: Bool = false) -> MenuBarPanel.Content {
        let state = MenuBarPanel.state(
            isLocked: locked, isRecording: bench.recorder.isRecording, isPaused: bench.recorder.isPaused)
        return MenuBarPanel.content(state, hasPatients: !app.appModel.patients.isEmpty)
    }

    func patientsOfferedInPanel() -> [Patient] { app.appModel.patients }

    func openKeyboardShortcuts() -> ShortcutsWindow {
        ShortcutsWindow(groupSizes: ShortcutCatalog.sections.map { $0.entries.count })
    }

    func chooseReportABug() -> FeedbackPage { FeedbackPage(url: FeedbackLink.url(.bug)) }

    func restPointerOnAHelpTip() -> HoverRest {
        var rest = HoverRest()
        rest.rest()
        return rest
    }

    /// Quit while the patient's session is being transcribed.
    func quit(whileTranscribing visit: PatientSession) async -> QuitOutcome {
        await quit(withWork: [
            InterruptedWork(kind: .transcription, patientID: visit.patient.id, sessionFolder: visit.session.folderName)
        ])
    }

    func deleteEveryPatient() throws {
        for patient in app.appModel.patients { try app.appModel.deletePatient(patient) }
    }

    /// The key combination the shortcuts list shows for an action, as typed: ⌘/, ⌘N, ⎋.
    func shortcut(titled title: String) -> String? {
        guard let shortcut = ShortcutCatalog.sections.flatMap(\.entries).first(where: { $0.title == title })?.shortcut
        else { return nil }
        let key = shortcut.key == .escape ? "⎋" : String(shortcut.key.character).uppercased()
        return (shortcut.modifiers == .command ? "⌘" : "") + key
    }
}

// MARK: - Then

@MainActor extension Then where Subject == MenuBarStart {
    func createdASessionAndIsRecording(_ bench: RecordingBench) {
        expect(subject.problem == nil, "the start reported a problem: \(subject.problem ?? "")")
        expectEqual(subject.sessionsAfter, subject.sessionsBefore + 1, "sessions after Start")
        expect(bench.recorder.isRecording, "recording did not begin")
        expectEqual(bench.recorder.active?.sessionID, subject.session?.id, "the session being recorded")
    }

    func createdNothingAndExplains(_ reason: String) {
        expectEqual(subject.sessionsAfter, subject.sessionsBefore, "sessions after a refused Start")
        expect(subject.problem?.contains(reason) == true, "the reason is not given: \(subject.problem ?? "nil")")
    }
}

@MainActor extension Then where Subject == MenuBarPanel.Content {
    func showsNotRecordingWithPickerAndStart() {
        expectEqual(subject.status, "Not recording", "the panel's status")
        expectEqual(subject.controls, ["Patient", "Start recording"], "the panel's controls")
    }

    func showsOnlyLockedAndUnlock() {
        expectEqual(subject.status, "Aletheia is locked", "the panel's status")
        expectEqual(subject.controls, ["Unlock"], "the panel's controls")
        expect(!subject.showsSessionDetail, "the locked panel shows recording or patient detail")
    }
}

@MainActor extension Then where Subject == String {
    func isTheSymbol(_ symbol: String) {
        expectEqual(subject, symbol, "the menu bar icon")
    }

    func readsAsName(_ name: String) {
        expectEqual(subject, name, "the patient shown in the panel")
    }
}

@MainActor extension Then where Subject == RecordingBench {
    func isPaused() {
        expect(subject.recorder.isPaused, "the recording is not paused")
        expect(subject.recorder.isRecording, "pausing ended the recording")
    }

    func isSavedAndIdle(_ files: RecordedFiles) {
        expect(!subject.recorder.isRecording && subject.recorder.active == nil, "the panel is not back to not recording")
        expect(files.micExists && files.callExists, "the recording was not saved")
    }
}

@MainActor extension Then where Subject == QuitOutcome {
    func savedInterruptedWork(whileTranscribing visit: PatientSession) {
        let work = [InterruptedWork(kind: .transcription, patientID: visit.patient.id, sessionFolder: visit.session.folderName)]
        expectEqual(subject.ledger.load(), work, "work listed for the next launch")
        expect(subject.job.wasShutDown, "running work was not wound down")
        expect(!subject.report.timedOut, "the quit waited out its deadline")
    }
}

@MainActor extension Then where Subject == String? {
    func isBound(to combination: String) {
        expectEqual(subject ?? "nothing", combination, "the key combination")
    }
}

@MainActor extension Then where Subject == ShortcutsWindow {
    func listsGroups(_ count: Int) {
        expectEqual(subject.groupSizes.count, count, "groups listed")
        expect(subject.groupSizes.allSatisfy { $0 > 0 }, "a group is empty")
    }
}

@MainActor extension Then where Subject == FeedbackPage {
    func isTheBugReportPage() {
        expectEqual(subject.url.host, Copy.feedbackHost, "the page's site")
        expectEqual(subject.items.first { $0.name == "type" }?.value, "bug", "the kind of report")
    }

    func carriesNoPatientInformation() {
        let extras = Set(subject.items.map(\.name)).subtracting(FeedbackLink.allowedQueryKeys)
        expect(extras.isEmpty, "the address carries \(extras.sorted())")
    }
}

@MainActor extension Then where Subject == HoverRest {
    func showsNothingAfter(seconds: Double) {
        expect(!subject.tipShows(after: seconds), "the tip showed after \(seconds)s")
    }

    func showsTheTipAfter(seconds: Double) {
        expect(subject.tipShows(after: seconds), "no tip after \(seconds)s")
    }

    func showsNothingOnceThePointerLeaves() {
        var rest = subject
        rest.leave()
        expect(!rest.tipShows(after: 3), "the tip showed after the pointer left")
    }
}

@MainActor extension Then where Subject == [Patient] {
    func areNone() {
        expectEqual(subject.count, 0, "patients offered to record")
    }
}

@MainActor extension Then where Subject == MenuBarStart {
    func offeredNoSecondRecording(whileRecording first: MenuBarStart, _ bench: RecordingBench) {
        expect(subject.session == nil, "a second session was created")
        expectEqual(subject.sessionsAfter, subject.sessionsBefore, "sessions after a second Start")
        expectEqual(bench.recorder.active?.sessionID, first.session?.id, "the session still being recorded")
    }
}
