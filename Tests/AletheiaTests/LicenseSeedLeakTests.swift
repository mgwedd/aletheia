import CryptoKit
import XCTest
@testable import Aletheia

/// No private half of a key the app trusts may be committed. Every base64 or hex
/// string in the repo that could be a 32-byte Ed25519 seed is tried as one; it fails
/// if the public key it gives is a production key, the dev key, or the retired dev key.
final class LicenseSeedLeakTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private let trusted: Set<String> = {
        var keys = Set(LicenseKeyring.productionPublicKeys.values)
        keys.insert("8KFp2hW7OwEzohfjyeq+7R4eZywqyDxNYBGU7YUzkSU=") // aletheia-dev-2
        keys.insert("l5KEG0cBMvhtV+s4ZO14Q7eFg172/V29cw1MehAF2lI=") // aletheia-dev-1, retired
        return keys
    }()

    private static let candidate = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9+/_-])([A-Za-z0-9+/_-]{43}=?|[0-9a-fA-F]{64})(?![A-Za-z0-9+/_=-])")

    private func seedBytes(_ text: String) -> Data? {
        if text.count == 64, text.allSatisfy(\.isHexDigit) {
            var bytes = Data()
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return bytes
        }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if base64.count == 43 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return data
    }

    private func textFiles() throws -> [(path: String, text: String)] {
        var files: [(String, String)] = []
        let skip: Set<String> = [".git", ".build", "build", "DerivedData", "node_modules"]
        let walker = try XCTUnwrap(FileManager.default.enumerator(
            at: repo, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]))
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true {
                if skip.contains(url.lastPathComponent) || url.pathExtension == "xcodeproj" { walker.skipDescendants() }
                continue
            }
            guard (values.fileSize ?? 0) < 2_000_000,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files.append((String(url.path.dropFirst(repo.path.count + 1)), text))
        }
        return files
    }

    func testNoTrustedSigningSeedIsInTheRepo() throws {
        let files = try textFiles()
        XCTAssertTrue(files.contains { $0.path == "Sources/App/Services/License/LicenseKeyring.swift" },
                      "the scan must cover the sources")
        for (path, text) in files {
            let range = NSRange(text.startIndex..., in: text)
            for match in Self.candidate.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text),
                      let seed = seedBytes(String(text[r])),
                      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { continue }
                let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
                XCTAssertFalse(trusted.contains(publicKey), "\(path) holds the private seed of a trusted license key")
            }
        }
    }

    func testTheScanFindsASeedWhenOneIsPresent() throws {
        let key = Curve25519.Signing.PrivateKey()
        let text = "seed: \(key.rawRepresentation.base64EncodedString())\n"
        let range = NSRange(text.startIndex..., in: text)
        let found = Self.candidate.matches(in: text, range: range).compactMap { match -> String? in
            guard let r = Range(match.range(at: 1), in: text), let seed = seedBytes(String(text[r])),
                  let derived = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
            return derived.publicKey.rawRepresentation.base64EncodedString()
        }
        XCTAssertEqual(found, [key.publicKey.rawRepresentation.base64EncodedString()])
    }
}
