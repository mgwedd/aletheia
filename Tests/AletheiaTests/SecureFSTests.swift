import XCTest
@testable import Aletheia

func posixMode(_ url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.posixPermissions] as? Int ?? -1) & 0o777
}

final class SecureFSTests: XCTestCase {
    private var tempRoot: URL!
    private var savedUmask: mode_t = 0

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecureFSTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        savedUmask = umask(0o000)   // the most permissive case
    }

    override func tearDownWithError() throws {
        umask(savedUmask)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testDirectoryIs0700() throws {
        let dir = tempRoot.appendingPathComponent("a/b/c", isDirectory: true)
        try SecureFS.createDirectory(at: dir)
        XCTAssertEqual(try posixMode(dir), 0o700)
    }

    func testFileIs0600UnderPermissiveUmask() throws {
        XCTAssertEqual(umask(0o000), 0o000, "the test runs with umask 000")
        let file = tempRoot.appendingPathComponent("data.bin")
        try SecureFS.write(Data("x".utf8), to: file)
        XCTAssertEqual(try posixMode(file), 0o600)
        XCTAssertEqual(try Data(contentsOf: file), Data("x".utf8))
    }

    func testRewriteReplacesContentsAndKeeps0600() throws {
        let file = tempRoot.appendingPathComponent("data.bin")
        try SecureFS.write(Data("one".utf8), to: file)
        try SecureFS.write(Data("two".utf8), to: file)
        XCTAssertEqual(try Data(contentsOf: file), Data("two".utf8))
        XCTAssertEqual(try posixMode(file), 0o600)
    }

    func testAtomicWriteLeavesNoWideTemp() throws {
        let file = tempRoot.appendingPathComponent("data.bin")
        try SecureFS.write(Data("x".utf8), to: file)
        // Nothing but the target remains, so no temp file is left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: tempRoot.path)
        XCTAssertEqual(names, ["data.bin"])

        // A failed write (target is a non-empty directory) cleans its temp up too.
        let blocked = tempRoot.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked.appendingPathComponent("inner"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try SecureFS.write(Data("y".utf8), to: blocked))
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: tempRoot.path))
        XCTAssertEqual(after, ["data.bin", "blocked"])
    }

    func testTightensExistingModes() throws {
        let dir = tempRoot.appendingPathComponent("wide", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("f")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        try SecureFS.createDirectory(at: dir)
        try SecureFS.tightenFile(at: file)
        XCTAssertEqual(try posixMode(dir), 0o700)
        XCTAssertEqual(try posixMode(file), 0o600)

        // Rewriting a wide file yields an owner-only one.
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        try SecureFS.write(Data("y".utf8), to: file)
        XCTAssertEqual(try posixMode(file), 0o600)
    }

    func testTighteningNeverWidensOrFollowsSymlinks() throws {
        let narrow = tempRoot.appendingPathComponent("narrow")
        FileManager.default.createFile(atPath: narrow.path, contents: nil, attributes: [.posixPermissions: 0o400])
        try SecureFS.tightenFile(at: narrow)
        XCTAssertEqual(try posixMode(narrow), 0o400)

        let target = tempRoot.appendingPathComponent("target")
        FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o644])
        let link = tempRoot.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try SecureFS.tightenFile(at: link)
        XCTAssertEqual(try posixMode(target), 0o644)

        XCTAssertNoThrow(try SecureFS.tightenFile(at: tempRoot.appendingPathComponent("missing")))
    }
}
