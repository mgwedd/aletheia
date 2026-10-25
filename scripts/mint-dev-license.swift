#!/usr/bin/env swift
// Mints a development license token signed with the dev-only key.
//
//   swift scripts/mint-dev-license.swift <licensee> [days=365] [tier=dev] [license-id]
//
// The dev private seed lives only under Tests/ (Tests/AletheiaTests/Fixtures/dev-license-signing-seed.txt).
// Only the dev tier (ALETHEIA_DEV builds) trusts the matching public key; a production build never does.
import CryptoKit
import Foundation

func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: mint-dev-license.swift <licensee> [days] [tier] [license-id]\n".utf8))
    exit(2)
}
let days = args.count > 2 ? (Double(args[2]) ?? 365) : 365
let tier = args.count > 3 ? args[3] : "dev"
let lid = args.count > 4 ? args[4] : "dev-" + UUID().uuidString.prefix(8).lowercased()

let script = URL(fileURLWithPath: CommandLine.arguments[0])
let seedURL = script.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/AletheiaTests/Fixtures/dev-license-signing-seed.txt")
guard let text = try? String(contentsOf: seedURL, encoding: .utf8),
      let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    FileHandle.standardError.write(Data("cannot read the dev seed at \(seedURL.path)\n".utf8))
    exit(1)
}

let now = Int(Date().timeIntervalSince1970)
let payload: [String: Any] = [
    "v": 1, "kid": "aletheia-dev-1", "lid": lid, "sub": args[1], "tier": tier,
    "iat": now, "exp": now + Int(days * 86400),
]
let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
let signed = "ALET1." + b64url(json)
let sig = try key.signature(for: Data(signed.utf8))
print(signed + "." + b64url(sig))
