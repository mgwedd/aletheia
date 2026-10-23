import XCTest
@testable import Aletheia

final class StagingDirectoryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("StagingPermsTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testStagingRootAndSessionDirectoryPermissionsAre0700() throws {
        let sessionID = UUID()
        let stagingDir = Store.stagingDir(for: sessionID, in: tempDir)

        try FileManager.default.createDirectory(
            at: stagingDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingDir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir.path)

        let rootAttrs = try FileManager.default.attributesOfItem(atPath: tempDir.path)
        let rootPerms = (rootAttrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(rootPerms, 0o700, "Staging root directory must have POSIX permissions 0o700")

        let sessionAttrs = try FileManager.default.attributesOfItem(atPath: stagingDir.path)
        let sessionPerms = (sessionAttrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(sessionPerms, 0o700, "Session staging directory must have POSIX permissions 0o700")
    }

    @MainActor
    func testRecorderCreatesStagingDirectoryWith0700Permissions() async throws {
        let stagingRoot = tempDir.appendingPathComponent("Staging", isDirectory: true)
        let recorder = SessionRecorder(stagingDirectoryURL: stagingRoot)
        let sessionID = UUID()

        recorder.audioCaptureStartOverride = { micURL, _ in
            try Data("sample".utf8).write(to: micURL)
        }

        let destDir = tempDir.appendingPathComponent("Dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let micDest = destDir.appendingPathComponent("mic.caf")
        let callDest = destDir.appendingPathComponent("call.caf")

        let error = await recorder.start(
            micURL: micDest,
            callURL: callDest,
            context: .init(sessionID: sessionID, patientID: UUID(), patientName: "Test", patientSlug: "test", sessionFolder: "test_session")
        )
        XCTAssertNil(error)

        let sessionStagingDir = stagingRoot.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionStagingDir.path))

        let attrs = try FileManager.default.attributesOfItem(atPath: sessionStagingDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700, "Recorder must create staging directory with 0o700 permissions")

        await recorder.stop()
    }
}
