import XCTest

final class SecuritySpec: AcceptanceCase {
    func test_SECURITY_01() async throws {
        try given.aFolderWithActivity()
        given.appLockIsOff()
        let before = when.openSecurityPane()
        then(before).listsAppLockFileVaultAuditLogAndNetwork()
        then(before).readsSomeProtectionsCouldBeStronger()
        then(before).marksAppLockForReview()
        then(before).marksFileVaultOK()
        then(before).marksTheAuditLogOK()

        given.appLockIsOn()
        try given.encryptionOn()
        let secured = when.openSecurityPane()
        then(secured).marksAppLockOK()
        then(secured).readsWellProtected()

        given.fileVaultIsOff()
        given.appRelaunched()
        then(when.openSecurityPane()).marksFileVaultForReview()
    }

    func test_SECURITY_02() async throws {
        then(try when.openNetworkAccessForAShippedBuild()).saysItCannotConnectToTheInternet()
    }

    func test_SECURITY_03() async throws {
        then(when.clickCopyUnderVerifyItYourself()).putsTheCodesignCommandOnTheClipboard()
    }

    func test_SECURITY_04() async throws {
        try pending("unlock and export entries are written by app and view closures with no model entry point to drive")
    }

    func test_SECURITY_05() async throws {
        try given.aFolderWithActivity()
        let run = try when.verifyIntegrity()
        then(run).saysIntegrityVerified()
        then(run).producesAReportOfTheEntries()
    }

    func test_SECURITY_06() async throws {
        try given.aFolderWithActivity()
        let entry = try when.editAnEntryOutsideAletheia()
        then(try when.verifyIntegrity()).saysIntegrityCheckFailed(atEntry: entry)
    }

    func test_SECURITY_07() async throws {
        try given.aFolderWithActivity()
        let doctor = try await when.openDoctor()
        then(doctor).groupsItsChecks()
        then(doctor).showsEachCheckAsOKWarningOrProblem()
    }

    func test_SECURITY_08() async throws {
        try given.aFolderWithActivity()
        let doctor = try await when.openDoctor()
        then(doctor).listsEveryCheck()
        then(doctor).holdsNoPatientNames()
    }
}
