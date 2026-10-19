import Foundation
import Security

/// Evaluates whether this running binary is Developer ID signed and notarized,
/// an ad-hoc local build, or unsigned. Pure enum with injectable inspector
/// for unit testing.
enum CodeSigningStatus: Equatable {
    case developerIDNotarized(teamID: String?)
    case adHoc
    case devBuild
    case unsigned
    case other(String)

    var description: String {
        switch self {
        case .developerIDNotarized:
            return "Developer ID signed and notarized by Apple"
        case .adHoc:
            return "Ad-hoc signed (development build; not notarized)"
        case .devBuild:
            return "Development build"
        case .unsigned:
            return "Unsigned build"
        case .other(let name):
            return "Signed (\(name))"
        }
    }

    /// Evaluates the current running app's code signature.
    static func current(inspector: () -> CodeSigningStatus = Self.inspectCurrentProcess) -> CodeSigningStatus {
        inspector()
    }

    static func inspectCurrentProcess() -> CodeSigningStatus {
        #if ALETHEIA_DEV
        return .devBuild
        #else
        var secCode: SecCode?
        guard SecCodeCopySelf([], &secCode) == errSecSuccess, let secCode else {
            return .unsigned
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(secCode, [], &staticCode) == errSecSuccess, let staticCode else {
            return .unsigned
        }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else {
            return .unsigned
        }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certs.first {
            let summary = SecCertificateCopySubjectSummary(first) as String? ?? ""
            if summary.contains("Developer ID Application") {
                return .developerIDNotarized(teamID: team)
            }
            return .other(summary)
        }
        if info[kSecCodeInfoIdentifier as String] != nil {
            return .adHoc
        }
        return .unsigned
        #endif
    }
}
