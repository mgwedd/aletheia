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
                .foregroundStyle(.orange)
            Text("Outdated: the transcript has changed since this note was generated.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Regenerate", action: onRegenerate)
                .disabled(!canRegenerate)
        }
        .font(.callout)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}
