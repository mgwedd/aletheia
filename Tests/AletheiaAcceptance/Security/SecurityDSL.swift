@testable import Aletheia
import AppKit
import CryptoKit
import Foundation
import XCTest

// MARK: - Subjects

/// The Security pane's posture card: its lines and the headline over them.
struct PostureCard {
    let items: [PostureItem]
    let headline: String

    func item(_ id: String) -> PostureItem? { items.first { $0.id == id } }
}

/// What the Network access card says about the shipped app.
struct NetworkCard {
    let status: NetworkAccessStatus
}

/// The clipboard after clicking Copy under "Verify it yourself".
struct VerifyItYourselfCopy {
    let clipboard: NamedClipboard
    let command: String
}

/// Verify integrity & export audit report, as the user sees its result.
struct IntegrityRun {
    let message: String
    let report: String
    let entryCount: Int
    let actionNames: [String]
}

/// A patient the Doctor report must keep out of what it shows.
struct DoctorPatient {
    let name: String
    let slug: String
    let folderID: String
}

/// The Doctor window after it has run, and the text Copy report would copy.
struct DoctorWindow {
    let report: DoctorReport
    let copiedText: String
    let patient: DoctorPatient
    let dataFolder: String
}

// MARK: - Given

enum SecurityFixtures {
    static let auditKey = SymmetricKey(data: Data(repeating: 7, count: 32))
    static let patientName = "Marguerite Okonkwo"
}

extension Given {
    /// A data folder with some activity: a patient, a deleted patient and an unlock.
    /// The activity log is signed with a test key instead of the real Keychain.
    func aFolderWithActivity() throws {
        app.appModel.auditKeyProvider = { SecurityFixtures.auditKey }
        app.appModel.rebuildStore()
        let kept = try XCTUnwrap(app.appModel.addPatient(name: SecurityFixtures.patientName), "could not add a patient")
        let store = try XCTUnwrap(app.appModel.store)
        _ = try store.createSession(for: kept, on: app.clock.now)
        let removed = try XCTUnwrap(app.appModel.addPatient(name: "Temporary Person"), "could not add a second patient")
        app.appModel.recordAudit(.appUnlocked)
        try app.appModel.deletePatient(removed)
    }

    func appLockIsOff() { app.settings.appLockEnabled = false }
    func appLockIsOn() { app.settings.appLockEnabled = true }
}

// MARK: - When

extension When {
    func openSecurityPane() -> PostureCard {
        let items = SecurityPosture.current(
            settings: app.settings, appModel: app.appModel, encryption: app.encryption,
            canAuthenticate: true, networkOnline: nil)
        return PostureCard(items: items, headline: SecurityPosture.headline(for: SecurityPosture.overall(items)))
    }

    /// The card for a shipped build: its facts come from the entitlements the
    /// Release build is signed with.
    func openNetworkAccessForAShippedBuild() throws -> NetworkCard {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func entitlements(_ path: String) throws -> NetworkAccessFacts.Entitlements {
            let data = try Data(contentsOf: repo.appendingPathComponent(path))
            let plist = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                "\(path) is not a property list")
            return .init(
                sandboxed: (plist["com.apple.security.app-sandbox"] as? Bool) ?? false,
                networkClient: (plist["com.apple.security.network.client"] as? Bool) ?? false)
        }
        let facts = NetworkAccessFacts(
            app: try entitlements("Sources/App/Resources/Aletheia.entitlements"),
            helper: try entitlements("Sources/NetworkHelper/NetworkHelper.entitlements"))
        return NetworkCard(status: NetworkAccessStatus(facts))
    }

    func clickCopyUnderVerifyItYourself() -> VerifyItYourselfCopy {
        let board = NSPasteboard(name: .init("aletheia-security-\(UUID().uuidString)"))
        NetworkHelperDisclosure.copyVerifyCommand(to: board)
        return VerifyItYourselfCopy(
            clipboard: NamedClipboard(pasteboard: board), command: NetworkHelperDisclosure.verifyCommand())
    }

    func verifyIntegrity() throws -> IntegrityRun {
        let audit = try XCTUnwrap(app.appModel.audit, "there is no activity log")
        let before = audit.entries()
        let outcome = try XCTUnwrap(app.appModel.verifyAuditLog(), "verifying did nothing")
        return IntegrityRun(
            message: outcome.message, report: outcome.report, entryCount: before.count,
            actionNames: before.map(\.action.displayName))
    }

    /// Changes one entry's text directly in the database, the way someone with
    /// access to the folder could. Returns the entry's number.
    func editAnEntryOutsideAletheia() throws -> Int64 {
        let audit = try XCTUnwrap(app.appModel.audit, "there is no activity log")
        let entries = audit.entries()
        let target = try XCTUnwrap(entries.dropFirst().first?.seq, "the log has too few entries to alter one")
        let core = try XCTUnwrap(audit.core, "the activity log has no database")
        try core.executeRaw("DROP TRIGGER IF EXISTS audit_no_update;")
        try core.executeRaw("UPDATE audit_events SET detail = 'edited' WHERE seq = \(target);")
        return target
    }

    func openDoctor() async throws -> DoctorWindow {
        let probes = LiveDoctorProbes.make(
            settings: app.settings, appModel: app.appModel,
            integrations: Integrations(settings: app.settings),
            recorder: SessionRecorder(stagingDirectoryURL: app.root.appendingPathComponent("staging")))
        let report = await DoctorRunner(probes: probes).run()
        let patient = try XCTUnwrap(
            app.appModel.patients.first { $0.name == SecurityFixtures.patientName }, "the patient is missing")
        return DoctorWindow(
            report: report, copiedText: report.plainText(),
            patient: DoctorPatient(name: patient.name, slug: patient.slug, folderID: patient.id.uuidString),
            dataFolder: app.root.path)
    }
}

// MARK: - Then

extension Then where Subject == PostureCard {
    func listsAppLockFileVaultAuditLogAndNetwork() {
        let expected = [("appLock", "App lock"), ("fileVault", "FileVault"), ("auditLog", "Audit log"), ("network", "Network activity")]
        for (id, title) in expected {
            expectEqual(subject.item(id)?.title ?? "(missing)", title, "the \(id) line")
        }
    }

    func readsSomeProtectionsCouldBeStronger() {
        expectEqual(subject.headline, Copy.postureNeedsWork, "the headline")
    }

    func readsWellProtected() {
        expectEqual(subject.headline, Copy.postureWellProtected, "the headline")
    }

    func marksAppLockForReview() {
        expectEqual(subject.item("appLock")?.level, .actionRecommended, "App lock")
    }

    func marksAppLockOK() {
        expectEqual(subject.item("appLock")?.level, .secure, "App lock")
    }

    func marksFileVaultOK() {
        expectEqual(subject.item("fileVault")?.level, .secure, "FileVault")
    }

    func marksFileVaultForReview() {
        expectEqual(subject.item("fileVault")?.level, .actionRecommended, "FileVault")
    }

    func marksTheAuditLogOK() {
        expectEqual(subject.item("auditLog")?.level, .secure, "the audit log")
    }
}

extension Then where Subject == NetworkCard {
    func saysItCannotConnectToTheInternet() {
        expectEqual(subject.status.headline, Copy.cannotConnect, "the headline")
    }
}

extension Then where Subject == VerifyItYourselfCopy {
    func putsTheCodesignCommandOnTheClipboard() {
        expect(subject.command.hasPrefix("codesign "), "expected a codesign command, found \(subject.command)")
        expectEqual(subject.clipboard.pastedText ?? "(nothing)", subject.command, "the clipboard")
    }
}

extension Then where Subject == IntegrityRun {
    func saysIntegrityVerified() {
        expect(subject.message.hasPrefix(Copy.integrityVerified), "expected \"\(Copy.integrityVerified)\", found \"\(subject.message)\"")
        expect(subject.message.contains("all \(subject.entryCount) entries"),
               "expected the message to count \(subject.entryCount) entries, found \"\(subject.message)\"")
    }

    func producesAReportOfTheEntries() {
        expect(subject.report.contains(subject.message), "expected the report to state the result \"\(subject.message)\"")
        for name in Set(subject.actionNames) where !subject.report.contains(name) {
            fail("expected the report to list \"\(name)\"")
        }
    }

    func saysIntegrityCheckFailed(atEntry number: Int64) {
        expect(subject.message.hasPrefix(Copy.integrityFailed), "expected \"\(Copy.integrityFailed)\", found \"\(subject.message)\"")
        expect(subject.message.contains("#\(number)"), "expected entry #\(number) in \"\(subject.message)\"")
    }
}

extension Then where Subject == DoctorWindow {
    func groupsItsChecks() {
        let groups = subject.report.grouped
        expect(groups.count >= 2, "expected the checks in groups, found \(groups.count)")
        expect(groups.map(\.category) == groups.map(\.category).sorted(), "expected the groups in display order")
        for group in groups {
            expect(!group.checks.isEmpty, "expected \"\(group.category.title)\" to hold checks")
            expect(group.checks.allSatisfy { $0.category == group.category }, "expected \"\(group.category.title)\" to hold only its own checks")
        }
    }

    func showsEachCheckAsOKWarningOrProblem() {
        let allowed = [Copy.doctorOK, Copy.doctorWarning, Copy.doctorProblem]
        expect(!subject.report.checks.isEmpty, "expected Doctor to run checks")
        for check in subject.report.checks {
            expect(allowed.contains(check.status.label), "expected \"\(check.title)\" to read OK, Warning or Problem, found \(check.status.label)")
        }
    }

    func holdsNoPatientNames() {
        let text = subject.copiedText
        var secrets = [subject.patient.name, subject.patient.slug, subject.patient.folderID, subject.dataFolder]
        secrets += subject.patient.name.split(separator: " ").map(String.init)
        for secret in secrets where text.range(of: secret, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            fail("expected the copied report to leave out \"\(secret)\"")
        }
    }

    func listsEveryCheck() {
        for check in subject.report.checks where !subject.copiedText.contains("[\(check.status.label)] \(check.title)") {
            fail("expected the copied report to list \"\(check.title)\"")
        }
    }
}
