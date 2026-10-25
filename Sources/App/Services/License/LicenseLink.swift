import Foundation

/// `aletheia://license?key=ALET1…`: the "Open in Aletheia" link on the key page.
/// It only fills in the license key field; nothing is installed until the user
/// clicks the button there, and the key is checked on this Mac as if pasted.
enum LicenseLink {
    static let scheme = "aletheia"
    static let host = "license"

    /// The key a license link carries, or nil for anything else.
    static func keyText(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              url.path.isEmpty || url.path == "/",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, items[0].name == "key",
              let key = items[0].value?.trimmingCharacters(in: .whitespacesAndNewlines),
              key.hasPrefix(LicenseVerifier.prefix + "."),
              key.utf8.count <= LicenseVerifier.maxLength
        else { return nil }
        return key
    }
}
