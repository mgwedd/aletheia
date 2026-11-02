import AppKit
import SwiftUI

/// "SOAP note ready", in the main window's corner whichever screen is open, with
/// a button that opens the note. Nothing shows until a note finishes.
struct NoteReadyToast: View {
    @ObservedObject var center: NoteReadyCenter

    var body: some View {
        Group {
            if let notice = center.notice {
                VStack(alignment: .leading, spacing: 8) {
                    Label(notice.title, systemImage: "checkmark.circle.fill")
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.ok.color)
                        .accessibilityIdentifier("noteReady.title")
                    Text(notice.detail)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                        .lineLimit(1)
                    HStack {
                        Spacer(minLength: 0)
                        Button(NoteReadyCenter.dismissButton) { center.dismiss() }
                            .buttonStyle(.themed)
                        Button(NoteReadyCenter.openButton) { center.open() }
                            .buttonStyle(.themePrimary)
                            .accessibilityIdentifier("noteReady.open")
                    }
                    .controlSize(.small)
                }
                .padding(14)
                .frame(width: 300, alignment: .leading)
                .themeCard()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("noteReady")
                .onAppear { Self.announce(notice.title) }
                .onChange(of: notice) { _, next in Self.announce(next.title) }
            }
        }
        .animation(.easeOut(duration: 0.15), value: center.notice)
    }

    /// Speaks the title (no patient name) for VoiceOver.
    private static func announce(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
