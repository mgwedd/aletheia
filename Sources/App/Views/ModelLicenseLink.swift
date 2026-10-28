import SwiftUI

/// "License: <name>" as a link, shown wherever a model download is offered, so
/// the terms can be read before the download starts. A Llama model also carries
/// the "Built with Llama" attribution its license asks for. The link opens in
/// the user's browser; the app itself fetches nothing.
struct ModelLicenseLink: View {
    let licenseName: String
    let licenseURL: URL
    var usePolicyURL: URL?
    var attribution: String?

    init(_ model: WhisperModel) {
        licenseName = model.licenseName
        licenseURL = model.licenseURL
    }

    init(_ model: LlamaModel) {
        licenseName = model.licenseName
        licenseURL = model.licenseURL
        usePolicyURL = model.acceptableUseURL
        attribution = model.attribution
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("License:")
                    .foregroundStyle(Theme.muted.color)
                Link(licenseName, destination: licenseURL)
                    .tint(Theme.accent.color)
                    .accessibilityIdentifier("model-license-link")
                if let usePolicyURL {
                    Text("·")
                        .foregroundStyle(Theme.muted.color)
                    Link("Acceptable Use Policy", destination: usePolicyURL)
                        .tint(Theme.accent.color)
                }
            }
            if let attribution {
                Text(attribution)
                    .foregroundStyle(Theme.muted.color)
            }
        }
        .font(Theme.Typography.caption)
        .accessibilityElement(children: .contain)
    }
}

extension LlamaModel {
    /// The same terms as plain text, for places that cannot hold a link (an
    /// alert's message).
    var licenseSummary: String {
        var parts = ["License: \(licenseName) (\(licenseURL.absoluteString))."]
        if let acceptableUseURL { parts.append("Acceptable Use Policy: \(acceptableUseURL.absoluteString).") }
        if let attribution { parts.append("\(attribution).") }
        return parts.joined(separator: " ")
    }
}
