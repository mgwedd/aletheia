import SwiftUI

/// Shown above a generated note when the transcript has been edited since the
/// note was generated, offering to regenerate it. Never shown for the
/// therapist's own session notes.
struct OutdatedNoteBanner: View {
    /// False when there is no transcript to regenerate from.
    var canRegenerate = true
    var onRegenerate: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Outdated: the transcript has changed since this note was generated.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Regenerate", action: onRegenerate)
                .buttonStyle(.themed)
                .controlSize(.small)
                .disabled(!canRegenerate)
        }
        .font(Theme.Typography.body)
        .foregroundStyle(Theme.highlightInk.color)
        .padding(12)
        .background(Theme.highlight.color, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
    }
}
