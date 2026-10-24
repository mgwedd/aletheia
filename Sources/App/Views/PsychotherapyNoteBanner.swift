import SwiftUI

/// Sits above the psychotherapy note: says the note is kept apart from the
/// clinical record.
struct PsychotherapyNoteBanner: View {
    var body: some View {
        Label(NoteKind.psychotherapyBanner, systemImage: "lock.doc")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.muted.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}
