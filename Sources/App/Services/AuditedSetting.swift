import Foundation

/// A security-relevant setting whose changes are written to the activity log.
/// The label and the value wording are fixed text here, so an entry can never
/// carry anything typed by the user. A setting is declared once in
/// `AuditedSettings`, and its `didSet` (or action) passes through
/// `AppSettings.audited(_:from:to:)`; `scripts/check-audit-wiring.sh` fails when
/// a setting listed in `scripts/audit-security-settings.txt` skips that call.
struct AuditedSetting<Value: Equatable> {
    let name: String
    let describe: (Value) -> String

    /// The log entry's note for `value`, e.g. "App lock: on".
    func detail(for value: Value) -> String { "\(name): \(describe(value))" }
}

enum AuditedSettings {
    private static func onOff(_ on: Bool) -> String { on ? "on" : "off" }

    static let appLock = AuditedSetting<Bool>(name: "App lock", describe: onOff)
    static let lockWhenHidden = AuditedSetting<Bool>(name: "Lock when hidden", describe: onOff)
    static let idleTimeout = AuditedSetting<Int>(name: "Idle lock timeout") {
        $0 == 0 ? "never" : "\($0) min"
    }
    static let spotlight = AuditedSetting<Bool>(name: "Spotlight indexing", describe: onOff)
    static let hideFromScreenSharing = AuditedSetting<Bool>(name: "Hide from screen sharing", describe: onOff)
    static let recordingConsentPolicy = AuditedSetting<ConsentPolicy>(name: "Recording consent") {
        $0.title.lowercased()
    }
    static let rememberKeyOnMac = AuditedSetting<Bool>(name: "Unlock automatically on this Mac", describe: onOff)
}
