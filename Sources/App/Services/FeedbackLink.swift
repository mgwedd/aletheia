import Foundation

/// Bug reports and feature requests go through the form on astrealabs.com,
/// opened in the browser. The app itself sends nothing.
///
/// The link fills in the project, the kind of report, and the app version,
/// build tier, macOS version and chip. Nothing about the user, the Mac's name
/// or any patient data goes in it.
enum FeedbackLink {
    enum Kind: String {
        case bug
        case feature
    }

    static let formURL = URL(string: "https://astrealabs.com/feedback")!

    /// The bug button at the foot of the sidebar, beside Settings.
    static let bugSymbol = "ladybug"
    static let bugHelp = "Report a bug (beta): opens the feedback form on astrealabs.com"

    /// The only query keys the link may carry.
    static let allowedQueryKeys: Set<String> = ["project", "type", "environment"]

    static func url(_ kind: Kind, environment: String = currentEnvironment) -> URL {
        var components = URLComponents(url: formURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "project", value: "aletheia"),
            URLQueryItem(name: "type", value: kind.rawValue),
            URLQueryItem(name: "environment", value: environment),
        ]
        return components.url!
    }

    static func environment(appVersion: String, tier: BuildTier, macOS: OperatingSystemVersion, appleSilicon: Bool) -> String {
        let os = "\(macOS.majorVersion).\(macOS.minorVersion).\(macOS.patchVersion)"
        return "Aletheia \(appVersion) (\(tier.rawValue)), macOS \(os), \(appleSilicon ? "Apple silicon" : "Intel")"
    }

    static var currentEnvironment: String {
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        return environment(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            tier: .compiled,
            macOS: ProcessInfo.processInfo.operatingSystemVersion,
            appleSilicon: appleSilicon
        )
    }
}
