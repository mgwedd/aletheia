import AppKit
import SwiftUI

/// The "Network access" card in Settings → Security. It reports what the
/// running app's own signed entitlements allow, read live (never a hard-coded
/// answer), what the bundled helper may fetch, and how to check both from
/// outside the app.
struct NetworkAccessView: View {
    @State private var facts = EntitlementReader.current()
    @State private var copied = false

    var body: some View {
        let status = NetworkAccessStatus(facts)
        let command = NetworkHelperDisclosure.verifyCommand()
        VStack(alignment: .leading, spacing: 8) {
            Text("Network access").eyebrowStyle()
            SettingsRowsCard {
                SettingsRow(title: status.headline, detail: status.detail) {
                    Chip(status.chipText, tone: Self.tone(status.tone))
                }
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)

                SettingsHairline()
                SettingsRow(title: "Network helper", detail: status.helperSummary) { EmptyView() }
                    .padding(.vertical, 12)
                SettingsHairline()
                VStack(alignment: .leading, spacing: 4) {
                    Text("It can connect only to")
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(Theme.text.color)
                    Text(NetworkHelperDisclosure.hosts.joined(separator: ", "))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                    Text("It can download only")
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(Theme.text.color)
                        .padding(.top, 8)
                    ForEach(NetworkHelperDisclosure.downloads, id: \.self) { line in
                        Text(line)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.muted.color)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)

                SettingsHairline()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Verify it yourself")
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(Theme.text.color)
                    Text("Run this in Terminal to list the app's entitlements. \"com.apple.security.network.client\" should not appear.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                    HStack(alignment: .center, spacing: 12) {
                        Text(command)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text.color)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.field.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Button(copied ? "Copied" : "Copy") { copy(command) }
                            .buttonStyle(.themed)
                    }
                    Text("To watch for connections as they happen, use a firewall such as LuLu or Little Snitch, or run nettop in Terminal.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            }
        }
        .onAppear { facts = EntitlementReader.current() }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private static func tone(_ tone: NetworkAccessStatus.Tone) -> Chip.Tone {
        switch tone {
        case .ok: return .ok
        case .warn: return .warn
        case .neutral: return .neutral
        }
    }
}
