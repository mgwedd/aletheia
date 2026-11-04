import Foundation

/// A Debug build shares the release app's bundle ID, so it opens the same
/// sandbox container. These names keep its preferences, data folder and
/// activity-log key apart from an installed release build on the same Mac.
/// Otherwise the two builds, signed differently and so holding different
/// Keychain keys, sign rows into one activity log and each reads the other's
/// rows as tampered.
enum DebugBuildIsolation {
    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The preferences suite, or nil for the app's own preferences.
    static func defaultsSuite(debug: Bool = isDebugBuild) -> String? {
        debug ? "com.astrealabs.aletheia.debug" : nil
    }

    /// The standard data folder's name under Application Support/Aletheia.
    static func dataFolderName(debug: Bool = isDebugBuild) -> String {
        debug ? "Data-Debug" : "Data"
    }

    /// The Keychain account that holds the activity-log signing key.
    static func auditKeyAccount(debug: Bool = isDebugBuild) -> String {
        debug ? "com.aletheia.audit-hmac-key.debug" : "com.aletheia.audit-hmac-key"
    }
}
