import XCTest

/// Raw file writes and directory creation in the app go through `SecureFS`, so
/// data-folder files are owner-only. A file that must keep a plain call is
/// listed here with the reason.
final class SecureFSSourceScanTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func appSources() throws -> [(path: String, text: String)] {
        let root = repo.appendingPathComponent("Sources/App")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return try files.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { ($0.path.replacingOccurrences(of: repo.path + "/", with: ""), try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Path (from the repo root) to the reason a raw call is acceptable there.
    static let allowlist: [String: String] = [
        "Sources/App/Services/SecureFS.swift": "the helper itself",
        "Sources/App/Services/AuditLog.swift": "routed after the audit-events change lands",
        "Sources/App/Services/Crypto/PrivateStaging.swift": "already creates its folder 0700 and its files 0600",
        "Sources/App/Services/SystemAudioCapture.swift": "already creates its folder 0700 and sets its files 0600",
        "Sources/App/Services/FileSaver.swift": "export to a location the user picks; keeps normal modes",
        "Sources/App/Services/PatientArchive.swift": "export to a location the user picks; keeps normal modes",
        "Sources/App/Services/AllRecordsExport.swift": "export to a location the user picks; keeps normal modes",
        "Sources/App/Services/Crypto/EncryptedBackupArchive.swift": "writes the backup archive to the backup destination, which may be a user-chosen drive",
        "Sources/App/Services/DataFolderMove.swift": "creates the parent of a data folder the user picked, which is not ours to restrict",
        "Sources/App/Services/OrphanAudioSweep.swift": "already creates its quarantine folder 0700",
        "Sources/App/Services/Llama/LlamaModelDownloader.swift": "model files hold no patient data",
        "Sources/App/Services/NetworkHelper/NetworkHelperClient.swift": "downloaded model files hold no patient data; staging file is already 0600",
        "Sources/App/Services/HarnessEval.swift": "developer evaluation harness, writes to a path given on the command line",
        "Sources/App/Services/HarnessRun.swift": "developer evaluation harness, writes to a path given on the command line",
    ]

    /// `Keystore.write(to:)` takes a folder and does its own secure write.
    private static let keystoreReceivers: Set<String> = ["keystore", "updated"]

    private func violations(in text: String) -> [String] {
        var found: [String] = []
        let writePattern = try! NSRegularExpression(pattern: #"(\w*)[?!]?\)?\.write\(to:"#)
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            if line.contains("createDirectory(") && !line.contains("SecureFS.createDirectory(") {
                found.append("line \(index + 1): \(trimmed)")
            }
            let range = NSRange(line.startIndex..., in: line)
            for match in writePattern.matches(in: line, range: range) {
                let receiver = (line as NSString).substring(with: match.range(at: 1))
                if !Self.keystoreReceivers.contains(receiver) { found.append("line \(index + 1): \(trimmed)") }
            }
        }
        return found
    }

    func testNoRawWritesOutsideTheAllowlist() throws {
        var report: [String] = []
        for (path, text) in try appSources() where Self.allowlist[path] == nil {
            for hit in violations(in: text) { report.append("\(path) \(hit)") }
        }
        XCTAssertTrue(report.isEmpty, "use SecureFS, or allowlist with a reason:\n" + report.joined(separator: "\n"))
    }

    func testAllowlistIsNotStale() throws {
        let sources = Dictionary(uniqueKeysWithValues: try appSources().map { ($0.path, $0.text) })
        for (path, reason) in Self.allowlist {
            let text = try XCTUnwrap(sources[path], "allowlisted file is gone: \(path)")
            XCTAssertFalse(reason.isEmpty, path)
            if path.hasSuffix("SecureFS.swift") { continue }
            XCTAssertFalse(violations(in: text).isEmpty, "\(path) no longer needs its allowlist entry")
        }
    }

    func testScanFlagsRawCalls() {
        XCTAssertFalse(violations(in: "try data.write(to: url, options: .atomic)").isEmpty)
        XCTAssertFalse(violations(in: "try fm.createDirectory(at: dir, withIntermediateDirectories: true)").isEmpty)
        XCTAssertFalse(violations(in: "try text.write(to: url, atomically: true, encoding: .utf8)").isEmpty)
        XCTAssertTrue(violations(in: "try SecureFS.createDirectory(at: dir)").isEmpty)
        XCTAssertTrue(violations(in: "try SecureFS.write(data, to: url)").isEmpty)
        XCTAssertTrue(violations(in: "try keystore.write(to: root)").isEmpty)
    }
}
