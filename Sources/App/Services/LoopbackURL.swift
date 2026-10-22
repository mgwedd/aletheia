import Foundation
import Darwin

/// The one rule for where Ollama may live: on this Mac. Used by settings, the
/// Ollama client and Doctor so they can't disagree.
enum LoopbackURL {
    static let defaultOllama = URL(string: "http://127.0.0.1:11434")!

    /// `url` if it is a plain `http` address with an explicit port whose host is
    /// `127.0.0.0/8`, `::1` or exactly `localhost`, and carries no user info;
    /// otherwise nil. IP hosts are parsed with `inet_pton`, never matched by prefix.
    static func validate(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http",
              url.user == nil, url.password == nil,
              url.port != nil,
              var host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" { return url }

        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return UInt32(bigEndian: v4.s_addr) >> 24 == 127 ? url : nil
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            var loopback = in6_addr()
            inet_pton(AF_INET6, "::1", &loopback)
            let same = withUnsafeBytes(of: &v6) { a in withUnsafeBytes(of: &loopback) { b in a.elementsEqual(b) } }
            return same ? url : nil
        }
        return nil
    }

    /// `validate` for a string a user typed or defaults stored.
    static func validate(_ text: String) -> URL? {
        URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(validate(_:))
    }
}
