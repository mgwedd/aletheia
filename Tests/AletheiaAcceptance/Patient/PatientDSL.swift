@testable import Aletheia
import Foundation
import XCTest

// MARK: - Subjects

/// What the sidebar shows for each patient, top to bottom.
struct PatientSidebar {
    struct Row: Equatable {
        let name: String
        let initials: String
        let subtitle: String
    }
    let rows: [Row]
}

/// What a patient's page shows.
struct PatientPage {
    let name: String
    let sessionSummary: String
    let profileRows: [Patient.ProfileRow]
    /// The profile card's empty-state sentence, when it would be shown.
    let emptyProfileMessage: String?
}

/// The result of asking to add a patient.
struct PatientAddition {
    let patient: Patient?
    let notice: FileVaultNotice?
    let savedCount: Int
}

/// The New Patient sheet's Add button for a typed name.
struct NewPatientSheet {
    let typedName: String
    let canAdd: Bool
}

/// The profile editor open on one patient; nothing is written until `save()`.
@MainActor
final class ProfileEditing {
    enum CloseOutcome: Equatable { case closed, asksToDiscard }

    fileprivate let app: InProcessDriver
    fileprivate(set) var draft: PatientProfileDraft
    private let id: UUID

    fileprivate init(app: InProcessDriver, patient: Patient) {
        self.app = app
        id = patient.id
        let shows = app.appModel.featureRegistry.contains(id: PatientMedicationsFeatureModule.id)
        draft = PatientProfileDraft(patient: patient, showsMedications: shows)
    }

    var showsMedicationsTable: Bool { draft.showsMedications }
    var canSave: Bool { draft.canSave }
    var nameProblem: String? { draft.nameProblem }
    var medicationCount: Int { draft.medications.count }
    var medicationsPlaceholder: String? {
        draft.medications.isEmpty ? PatientProfileDraft.noMedicationsMessage : nil
    }

    func setName(_ text: String) { draft.name = text }
    func setClinicalHistory(_ text: String) { draft.clinicalHistory = text }
    func setNotes(_ text: String) { draft.notes = text }
    func setRecordingConsent(_ choice: ConsentPolicyChoice) { draft.recordingConsent = choice }
    var recordingConsentChoices: [String] { ConsentPolicyChoice.allCases.map(\.title) }
    func addMedication() { draft.addMedication() }
    func removeMedication(at index: Int) { draft.removeMedication(id: draft.medications[index].id) }

    func fillMedication(at index: Int, name: String, dose: String) {
        draft.medications[index].name = name
        draft.medications[index].dose = dose
    }

    func save() {
        guard draft.canSave else { return }
        let draft = draft
        app.appModel.updatePatient(id: id) { draft.apply(to: &$0) }
    }

    /// Cancel or close: with unsaved changes the editor asks first.
    func cancel() -> CloseOutcome { draft.needsDiscardConfirmation ? .asksToDiscard : .closed }
}

/// The delete-patient confirmation for one patient.
@MainActor
struct PatientDeletion {
    fileprivate let app: InProcessDriver
    fileprivate let patient: Patient
    let folder: URL
    let typedName: String
    /// Everything the confirmation sheet says, in reading order.
    let notice: [String]

    var deleteEnabled: Bool { PatientDeletionConfirmation.matches(typed: typedName, patientName: patient.name) }

    func confirm() throws {
        guard deleteEnabled else { return }
        try app.appModel.deletePatient(patient)
    }
}

/// A place on disk, for "is it gone".
struct DataLocation {
    let url: URL
    let probe: DataFolderProbe
}

// MARK: - Given

extension Given {
    /// Adds patients the way the New Patient sheet does.
    @discardableResult
    func patient(named name: String) async throws -> Patient {
        try XCTUnwrap(app.appModel.addPatient(name: name), "could not set up patient \(name)")
    }

    func sessions(_ count: Int, for patient: Patient) async throws {
        let store = try XCTUnwrap(app.appModel.store)
        for offset in 0..<count {
            _ = try store.createSession(for: patient, on: app.clock.now.addingTimeInterval(Double(offset) * 86_400))
        }
        app.appModel.refreshPatients()
    }

    /// Fills the profile in directly, as an earlier edit would have.
    func profile(of patient: Patient, clinicalHistory: String = "", notes: String = "",
                 medications: [(name: String, dose: String)] = []) async throws {
        app.appModel.updatePatient(id: patient.id) {
            $0.clinicalHistory = clinicalHistory
            $0.notes = notes
            $0.medications = medications.map { Medication(name: $0.name, dose: $0.dose) }
        }
    }

    func folder(of patient: Patient) throws -> DataLocation {
        let store = try XCTUnwrap(app.appModel.store)
        return DataLocation(url: store.patientDir(for: patient), probe: app.probe)
    }
}

// MARK: - When

extension When {
    @discardableResult
    func addPatient(named name: String) async throws -> PatientAddition {
        app.appModel.fileVaultNotice = nil
        let patient = app.appModel.addPatient(name: name)
        let saved = (try? app.appModel.store?.listPatients().count) ?? 0
        return PatientAddition(patient: patient, notice: app.appModel.fileVaultNotice, savedCount: saved)
    }

    func typeIntoNewPatientSheet(_ text: String) -> NewPatientSheet {
        NewPatientSheet(typedName: text, canAdd: AddPatientSheet.canSubmit(text))
    }

    func lookAtSidebar() -> PatientSidebar {
        let store = app.appModel.store
        let rows = app.appModel.patients.map { patient -> PatientSidebar.Row in
            let meta = store?.fastSessionMeta(for: patient)
            return PatientSidebar.Row(
                name: patient.name,
                initials: PatientInitials.from(patient.name),
                subtitle: PatientSessionText.rowSubtitle(
                    patient: patient, count: meta?.count ?? 0, newest: meta?.newestDate))
        }
        return PatientSidebar(rows: rows)
    }

    func openPage(of patient: Patient) throws -> PatientPage {
        let current = try XCTUnwrap(app.appModel.patients.first { $0.id == patient.id }, "patient is not listed")
        let sessions = try XCTUnwrap(app.appModel.store).listSessions(for: current)
        let rows = current.profileRows(
            includeMedications: app.appModel.featureRegistry.contains(id: PatientMedicationsFeatureModule.id))
        return PatientPage(
            name: current.name,
            sessionSummary: PatientSessionText.summary(count: sessions.count),
            profileRows: rows,
            emptyProfileMessage: rows.isEmpty ? PatientProfileDraft.nothingRecordedMessage : nil)
    }

    func editProfile(of patient: Patient) throws -> ProfileEditing {
        let current = try XCTUnwrap(app.appModel.patients.first { $0.id == patient.id }, "patient is not listed")
        return ProfileEditing(app: app, patient: current)
    }

    func askToDeletePatient(_ patient: Patient, typing typed: String) throws -> PatientDeletion {
        let store = try XCTUnwrap(app.appModel.store)
        let sessionDates = try store.listSessions(for: patient).map(\.date)
        let notice = DeletePatientConfirmation(patientName: patient.name, sessionDates: sessionDates).paragraphs
        return PatientDeletion(
            app: app, patient: patient, folder: store.patientDir(for: patient), typedName: typed, notice: notice)
    }

    /// The patient as stored on disk, read back fresh.
    func readStoredPatient(_ patient: Patient) throws -> Patient {
        let store = try XCTUnwrap(app.appModel.store)
        return try XCTUnwrap(try store.listPatients().first { $0.id == patient.id }, "patient is not on disk")
    }
}

// MARK: - Then

extension Then where Subject == PatientAddition {
    func addedPatient(named name: String) {
        guard let patient = subject.patient else { return fail("expected a patient named \(name) to be added, none was") }
        expectEqual(patient.name, name, "the new patient's name")
    }

    func addedNobody() {
        expect(subject.patient == nil, "expected no patient to be added, found \(subject.patient?.name ?? "")")
        expectEqual(subject.savedCount, 0, "patients saved")
    }

    func wasBlockedByFileVault() {
        expect(subject.patient == nil, "expected no patient to be added while FileVault is off")
        expectEqual(subject.notice?.title, Copy.turnOnFileVault, "the alert title")
        expectEqual(subject.savedCount, 0, "patients saved")
    }
}

extension Then where Subject == NewPatientSheet {
    func addIsDisabled() {
        expect(!subject.canAdd, "expected Add to be disabled for \(subject.typedName.debugDescription)")
    }

    func addIsEnabled() {
        expect(subject.canAdd, "expected Add to be enabled for \(subject.typedName.debugDescription)")
    }
}

extension Then where Subject == PatientPage {
    func showsName(_ name: String) { expectEqual(subject.name, name, "the page's name") }
    func showsNoSessions() { expectEqual(subject.sessionSummary, Copy.noSessions, "the session count") }

    func profileShowsOnly(_ labels: [String]) {
        expectEqual(subject.profileRows.map(\.label), labels, "the profile card rows")
    }

    func profileSaysNothingRecorded() {
        expect(subject.profileRows.isEmpty, "expected no profile rows, found \(subject.profileRows.map(\.label))")
        expect(subject.emptyProfileMessage?.hasPrefix(Copy.nothingRecordedYet) == true,
               "expected \"\(Copy.nothingRecordedYet)\", found \(subject.emptyProfileMessage ?? "no message")")
    }

    func profileRow(_ label: String, reads text: String) {
        expectEqual(subject.profileRows.first { $0.label == label }?.text, text, "the \(label) row")
    }
}

extension Then where Subject == PatientSidebar {
    func listsPatients(inOrder names: [String]) {
        expectEqual(subject.rows.map(\.name), names, "the patients listed")
    }

    func showsInitials(_ initials: [String]) {
        expectEqual(subject.rows.map(\.initials), initials, "the initials")
    }

    func showsAddedDates(in date: Date) {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        let expected = "Added \(formatter.string(from: date))"
        for row in subject.rows {
            expectEqual(row.subtitle, expected, "\(row.name)'s subtitle")
        }
    }

    func isEmpty() { expect(subject.rows.isEmpty, "expected no patients, found \(subject.rows.map(\.name))") }
}

extension Then where Subject == Patient {
    func hasNotes(_ notes: String) { expectEqual(subject.notes, notes, "the saved notes") }
    func isNamed(_ name: String) { expectEqual(subject.name, name, "the saved name") }
    func hasMedications(_ expected: [String]) {
        expectEqual(subject.medications.map { "\($0.name) \($0.dose)" }, expected, "the stored medications")
    }
}

@MainActor
extension Then where Subject == ProfileEditing {
    func cannotSave(because problem: String) {
        expect(!subject.canSave, "expected Save changes to be disabled")
        expectEqual(subject.nameProblem, problem, "the problem shown under the name")
    }

    func hasMedicationRows(_ count: Int) { expectEqual(subject.medicationCount, count, "medication rows") }

    func readsNoMedications() {
        expectEqual(subject.medicationsPlaceholder, Copy.noMedicationsRecorded, "the empty medications text")
    }

    func hidesMedicationsTable() {
        expect(!subject.showsMedicationsTable, "expected no Medications table in this build")
    }
}

extension Then where Subject == ProfileEditing.CloseOutcome {
    func closesWithoutAsking() { expectEqual(subject, .closed, "closing with nothing changed") }
    func asksToDiscard() { expectEqual(subject, .asksToDiscard, "closing with unsaved changes") }
}

@MainActor
extension Then where Subject == PatientDeletion {
    func deleteIsDisabled() { expect(!subject.deleteEnabled, "expected Delete Patient to be disabled for \(subject.typedName.debugDescription)") }
    func deleteIsEnabled() { expect(subject.deleteEnabled, "expected Delete Patient to be enabled for \(subject.typedName.debugDescription)") }

    /// The sheet names where copies can remain, so deleting is not mistaken for erasing everywhere.
    func namesTheCopiesThatRemain() {
        let text = subject.notice.joined(separator: "\n")
        for phrase in [Copy.deleteNoticeBackupsFolder, Copy.deleteNoticeTimeMachine, Copy.deleteNoticeExports] {
            expect(text.contains(phrase), "expected the confirmation to mention \"\(phrase)\", it says: \(text)")
        }
    }
}

extension Then where Subject == DataLocation {
    func isGone() {
        let left = subject.probe.files(under: subject.url)
        expect(!subject.probe.exists(subject.url), "expected \(subject.url.lastPathComponent) to be gone, found it with \(left.count) files")
    }

    func exists() { expect(subject.probe.exists(subject.url), "expected \(subject.url.lastPathComponent) to exist") }
}

// MARK: - Sidebar width

/// The patients sidebar's width before and after its edge was dragged.
struct SidebarDrag {
    let before: CGFloat
    let after: CGFloat
    let narrowest: CGFloat
    let widest: CGFloat
    /// Dragged far enough left, the sidebar collapses instead.
    let collapsed: Bool
}

extension When {
    func dragSidebarEdge(by points: CGFloat) -> SidebarDrag {
        let before = SidebarLayout.idealWidth
        return SidebarDrag(
            before: before,
            after: SidebarLayout.width(proposed: before + points),
            narrowest: SidebarLayout.minWidth,
            widest: SidebarLayout.maxWidth,
            collapsed: before + points < SidebarLayout.collapseWidth)
    }
}

/// The hidden sidebar after a drag from the window's left edge.
struct SidebarReveal {
    let shown: Bool
    let width: CGFloat
}

extension When {
    func dragFromWindowEdge(by points: CGFloat) -> SidebarReveal {
        let shown = points >= SidebarLayout.collapseWidth
        return SidebarReveal(shown: shown, width: shown ? SidebarLayout.width(proposed: points) : 0)
    }
}

extension Then where Subject == SidebarReveal {
    func bringsTheSidebarBack() {
        expect(subject.shown, "the sidebar stayed hidden after a drag from the window's edge")
        expect(subject.width >= SidebarLayout.minWidth, "the sidebar came back \(subject.width) wide")
    }

    func leavesTheSidebarHidden() {
        expect(!subject.shown, "a short drag from the window's edge showed the sidebar")
    }
}

/// The patients sidebar as Aletheia lays it out after a quit and reopen.
struct ReopenedSidebar {
    let shown: Bool
    let width: CGFloat
    /// Its width before the edge was dragged.
    let startWidth: CGFloat = SidebarLayout.idealWidth
}

extension When {
    func dragSidebarEdgeAndReopen(by points: CGFloat) -> ReopenedSidebar {
        app.settings.sidebarWidth = Double(SidebarLayout.width(proposed: SidebarLayout.idealWidth + points))
        return reopenSidebar()
    }

    func hideSidebarAndReopen() -> ReopenedSidebar {
        app.settings.sidebarShown = false
        return reopenSidebar()
    }

    private func reopenSidebar() -> ReopenedSidebar {
        app.relaunch(tier: app.tier)
        return ReopenedSidebar(shown: app.settings.sidebarShown, width: CGFloat(app.settings.sidebarWidth))
    }
}

extension Then where Subject == ReopenedSidebar {
    func reopensShowing(widenedBy points: CGFloat) {
        expect(subject.shown, "the sidebar reopened hidden")
        expectEqual(subject.width - subject.startWidth, points, "how much wider the sidebar reopened")
    }

    func reopensHidden() {
        expect(!subject.shown, "the sidebar reopened showing after it was hidden")
    }
}

extension Then where Subject == SidebarDrag {
    func movesTheSidebarBy(_ points: CGFloat) {
        expectEqual(subject.after - subject.before, points, "how far the sidebar's edge moved")
    }

    func staysUsable() {
        expect(!subject.collapsed, "the sidebar collapsed")
        expect(subject.after >= subject.narrowest, "the sidebar narrowed to \(subject.after), under \(subject.narrowest)")
        expect(subject.after <= subject.widest, "the sidebar widened to \(subject.after), over \(subject.widest)")
        expect(subject.narrowest >= 200, "the sidebar's narrowest width \(subject.narrowest) cuts off patient names")
    }

    func collapsesTheSidebar() {
        expect(subject.collapsed, "the sidebar stayed open after its edge was dragged far past its narrowest width")
    }
}
