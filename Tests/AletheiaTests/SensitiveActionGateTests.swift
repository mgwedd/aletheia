import XCTest
import LocalAuthentication
@testable import Aletheia

@MainActor
final class SensitiveActionGateTests: XCTestCase {
    private final class FakeAuthenticator: UnlockAuthenticator {
        enum Answer { case success, cancel, denied }
        var answer: Answer
        private(set) var reasons: [String] = []
        init(_ answer: Answer) { self.answer = answer }
        func authenticate(reason: String) async throws -> Bool {
            reasons.append(reason)
            switch answer {
            case .success: return true
            case .cancel: throw LAError(.userCancel)
            case .denied: return false
            }
        }
    }

    private func gate(_ auth: FakeAuthenticator, canAuthenticate: Bool = true) -> SensitiveActionGate {
        SensitiveActionGate(authenticator: auth, canAuthenticate: { canAuthenticate })
    }

    func testEveryActionIsRefusedWhenAuthenticationIsCancelled() async {
        for action in SensitiveAction.allCases {
            let auth = FakeAuthenticator(.cancel)
            var ran = 0
            let result = await gate(auth).perform(action) { ran += 1 }
            XCTAssertFalse(result, "\(action)")
            XCTAssertEqual(ran, 0, "\(action) must not run after a cancel")
            XCTAssertEqual(auth.reasons, [action.authenticationReason])
        }
    }

    func testDeniedAuthenticationIsNotSuccess() async {
        var ran = 0
        let result = await gate(FakeAuthenticator(.denied)).perform(.turnOffAppLock) { ran += 1 }
        XCTAssertFalse(result)
        XCTAssertEqual(ran, 0)
    }

    func testSuccessRunsTheActionExactlyOnce() async {
        for action in SensitiveAction.allCases {
            let auth = FakeAuthenticator(.success)
            var ran = 0
            let result = await gate(auth).perform(action) { ran += 1 }
            XCTAssertTrue(result, "\(action)")
            XCTAssertEqual(ran, 1, "\(action)")
            XCTAssertEqual(auth.reasons.count, 1)
        }
    }

    func testAuthenticationIsNeverReused() async {
        let auth = FakeAuthenticator(.success)
        let gate = gate(auth)
        var ran = 0
        await gate.perform(.exportAllRecords) { ran += 1 }
        auth.answer = .cancel
        await gate.perform(.exportAllRecords) { ran += 1 }
        XCTAssertEqual(ran, 1, "a second action needs its own check")
        XCTAssertEqual(auth.reasons.count, 2)
    }

    func testMacWithoutAuthenticationDoesNotLockTheUserOut() async {
        let auth = FakeAuthenticator(.cancel)
        var ran = 0
        await gate(auth, canAuthenticate: false).perform(.disableEncryption) { ran += 1 }
        XCTAssertEqual(ran, 1)
        XCTAssertTrue(auth.reasons.isEmpty)
    }

    func testPromptWordingFitsTheSystemSheet() {
        for action in SensitiveAction.allCases {
            let reason = action.authenticationReason
            XCTAssertEqual(reason.first?.isLowercase, true, reason)
            XCTAssertFalse(reason.hasSuffix("."), reason)
            XCTAssertFalse(reason.contains("Aletheia"), reason)
        }
    }

    func testOnlyALongerWaitOrNeverWeakensTheIdleLock() {
        typealias T = IdleAutoLockTimeout
        XCTAssertTrue(IdleLockChange.weakens(from: .fifteenMinutes, to: .off))
        XCTAssertTrue(IdleLockChange.weakens(from: .fiveMinutes, to: .sixtyMinutes))
        XCTAssertFalse(IdleLockChange.weakens(from: .fifteenMinutes, to: .fiveMinutes))
        XCTAssertFalse(IdleLockChange.weakens(from: .off, to: .fifteenMinutes))
        XCTAssertFalse(IdleLockChange.weakens(from: .thirtyMinutes, to: .thirtyMinutes))
        XCTAssertFalse(IdleLockChange.weakens(from: .off, to: .off))
    }

    func testTheTestHostAuthenticatorNeverApproves() async {
        let auth = UnlockAuthenticatorFactory.make(environment: ["XCTestConfigurationFilePath": "x"])
        XCTAssertTrue(auth is NonPromptingUnlockAuthenticator)
        let result = await SensitiveActionGate(authenticator: auth, canAuthenticate: { true })
            .perform(.changePassphrase) { XCTFail("must not run") }
        XCTAssertFalse(result)
    }

    // MARK: Call sites

    private var settingsSource: String {
        get throws {
            let repo = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try ["Sources/App/Views/SettingsView.swift", "Sources/App/Views/Settings/AuditLogSection.swift"]
                .map { try String(contentsOf: repo.appendingPathComponent($0), encoding: .utf8) }
                .joined(separator: "\n")
        }
    }

    func testEverySettingsCallSiteGoesThroughTheGate() throws {
        let source = try settingsSource
        let required: [(action: String, call: String)] = [
            ("turnOffAppLock", "settings.appLockEnabled = false"),
            ("weakenIdleLock", "settings.idleAutoLockMinutes = newValue.rawValue"),
            ("disableEncryption", "disableEncryption()"),
            ("changePassphrase", "showChangePassphraseSheet = true"),
            ("changeDataFolder", "chooseFolder()"),
            ("exportActivityLog", "exportLog()"),
            ("exportActivityLog", "verifyIntegrityAndExportReport()"),
            ("exportAllRecords", "chooseExportAllFolder()"),
        ]
        for (action, call) in required {
            XCTAssertTrue(
                source.contains("requireAuth(.\(action)) { \(call)"),
                "\(call) must run inside requireAuth(.\(action))"
            )
        }
        // The app-lock switch binds to the gated binding, never straight to the setting.
        XCTAssertFalse(source.contains("$settings.appLockEnabled"))
        XCTAssertFalse(source.contains("$settings.idleAutoLockMinutes"))
    }

    func testGatedCallsAreNotAlsoReachableUngated() throws {
        let source = try settingsSource
        // Each gated function is only invoked from inside requireAuth.
        for call in ["disableEncryption()", "chooseFolder()", "exportLog()", "verifyIntegrityAndExportReport()"] {
            let all = source.components(separatedBy: call).count - 1
            let gated = source.components(separatedBy: "{ \(call)").count - 1
            // one extra occurrence is the function declaration ("func name()")
            XCTAssertEqual(all, gated + 1, "\(call) has an ungated caller")
        }
    }
}
