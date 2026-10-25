import XCTest

final class EncryptSpec: AcceptanceCase {
    private let secret = "panic attacks since March"

    func test_ENCRYPT_01() async throws {
        given.buildIs(.release)
        then(when.lookForEncryptionControls()).offersNone()

        given.buildIs(.dev)
        then(when.lookForEncryptionControls()).offersEncryption()
    }

    func test_ENCRYPT_02() async throws {
        then(when.typePassphrase("short pass")).keepsContinueDisabled()
        then(when.typePassphrase("abc")).readsWeak()
    }

    func test_ENCRYPT_03() async throws {
        let step = try when.reachTheRecoveryKeyStep()

        then(step).shows24Words()
        then(step).copyWordsKeepsThemOffClipboardManagers()
        then(step).savesThePDFOutsideTheDataFolderOnly()
    }

    func test_ENCRYPT_04() async throws {
        try pending("the two acknowledgement boxes are private view state; needs a UI driver")
    }

    func test_ENCRYPT_05() async throws {
        let session = try await given.aSession(withSecret: secret)
        then(try when.openFilesInTerminal(of: session)).showsReadableContent()

        try when.turnOnEncryption()

        let folder = try when.openFilesInTerminal(of: session)
        then(folder).showsNoReadableContent()
        then(folder).keepsFolderNamesReadable()
    }

    func test_ENCRYPT_06() async throws {
        try await given.aSession(withSecret: secret)
        try given.encryptionOn()
        given.unlockAutomaticallyOnThisMacIsOff()

        let reopened = when.reopen()

        then(reopened).asksForThePassphrase()
        then(reopened).showsNoPatients()

        when.enterPassphrase(EncryptionFixtures.passphrase, in: reopened)

        then(reopened).showsPatients(["Jane Doe"])
    }

    func test_ENCRYPT_07() async throws {
        try await given.aSession(withSecret: secret)
        try given.encryptionOn()
        given.unlockAutomaticallyOnThisMacIsOff()
        _ = when.reopen()

        let attempts = when.enterWrongPassphrase(times: 5)

        then(attempts).saysItDidntUnlockTheData()
        then(attempts).addsAWait()
    }

    func test_ENCRYPT_08() async throws {
        let session = try await given.aSession(withSecret: secret)
        let recoveryKey = try given.encryptionOn()

        let change = try when.changePassphrase(
            to: "a different long passphrase", recoveryKey: recoveryKey, seeded: session)

        then(change).asksForTheCurrentPassphrase()
        then(change).opensWithOnlyTheNewPassphrase()
        then(change).keepsTheRecoveryKeyWorking()
    }

    func test_ENCRYPT_09() async throws {
        let session = try await given.aSession(withSecret: secret)
        try given.encryptionOn()

        let off = try when.turnOffEncryption(seeded: session)

        then(off).keptTheKeyWhileAFileCouldNotBeDecrypted()
        then(off).decryptedEverythingBeforeRemovingTheKey()
    }

    func test_ENCRYPT_10() async throws {
        let session = try await given.aSession(withSecret: secret)
        try given.encryptionOn()

        let stopped = try await when.stopRecordingAfterTheFolderLocked(of: session)

        then(stopped).keepsTheAudioOutOfTheSessionFolder()
        then(stopped).doesNotStartTranscription()

        let reopened = try when.reopenAndEnterThePassphrase(after: stopped)

        then(reopened).addsTheAudioToTheSession()
    }
}
