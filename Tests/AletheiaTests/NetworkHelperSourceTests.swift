import XCTest
@testable import Aletheia

/// Structural guards: what may cross to the helper, and who may use the network.
final class NetworkHelperSourceTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every Swift file under `Sources/`, as (relative path, contents).
    private func allSources() throws -> [(path: String, text: String)] {
        let root = repo.appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(repo.path.count + 1))
            files.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    /// The app may send the helper an integer, a file handle and a progress
    /// proxy: never a String, URL or Data. (`Data` appears only in a reply.)
    func testProtocolSendsNoStringURLOrDataToTheHelper() throws {
        let text = try source("Sources/NetworkHelperShared/NetworkHelperProtocol.swift")
        let start = try XCTUnwrap(text.range(of: "@objc protocol NetworkHelperProtocol"))
        let body = String(text[start.lowerBound...])
        let end = try XCTUnwrap(body.range(of: "\n}\n"))
        let declaration = String(body[..<end.lowerBound])

        let funcs = declaration.split(separator: "\n").filter { $0.contains("func ") }
        XCTAssertEqual(funcs.count, 2, "the helper's command set is exactly two calls")
        for line in funcs {
            // Drop the reply closure: what comes back may carry Data.
            let request = line.components(separatedBy: "reply:")[0]
            for banned in ["String", "URL", "Data", "NSString", "NSURL", "NSData", "Any"] {
                XCTAssertFalse(
                    request.range(of: "\\b\(banned)\\b", options: .regularExpression) != nil,
                    "\(banned) must not travel app -> helper: \(line)")
            }
        }
        XCTAssertTrue(declaration.contains("asset: Int"))
    }

    /// Only the helper (and the shared protocol file, which names no network
    /// API) may touch the network.
    func testNetworkAPIsAppearOnlyInTheHelper() throws {
        let banned = ["URLSession", "NWConnection", "CFNetwork", "socket(", "URLConnection", "CFStream"]
        var offenders: [String] = []
        for (path, text) in try allSources() where !path.hasPrefix("Sources/NetworkHelper/") {
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for token in banned where code.contains(token) {
                offenders.append("\(path): \(token)")
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testTheHelperDoesTouchTheNetwork() throws {
        XCTAssertTrue(try source("Sources/NetworkHelper/HelperFetcher.swift").contains("URLSession"))
    }

    /// The helper never links the app's patient-data code: it compiles only its
    /// own folder and the shared protocol.
    func testHelperTargetCompilesOnlyItsOwnSources() throws {
        let yml = try source("project.yml")
        let start = try XCTUnwrap(yml.range(of: "  AletheiaNetworkHelper:"))
        let rest = yml[start.lowerBound...].split(separator: "\n").dropFirst()
        var block: [Substring] = []
        for line in rest {
            if !line.hasPrefix("  ") || (line.hasPrefix("  ") && !line.hasPrefix("   ") && !line.isEmpty) { break }
            block.append(line)
        }
        let paths = block.filter { $0.contains("- path:") }.map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(Set(paths), ["- path: Sources/NetworkHelper", "- path: Sources/NetworkHelperShared"])
    }
}
