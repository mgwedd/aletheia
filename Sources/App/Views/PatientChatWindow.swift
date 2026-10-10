import SwiftUI
import AppKit

/// The patient-wide chat in its own window rather than a sheet, so it can be
/// resized by dragging its edges, taken full screen, and closed with ⌘W like any
/// other window. One window per patient: asking again focuses the open one.
struct PatientChatWindow: View {
    static let windowID = "patient-chat"

    let patientID: UUID?

    @EnvironmentObject private var appModel: AppModel

    private var patient: Patient? {
        guard let patientID else { return nil }
        return appModel.patients.first { $0.id == patientID }
    }

    var body: some View {
        Group {
            if let patient {
                PatientChatView(patient: patient) { NSApp.keyWindow?.performClose(nil) }
                    .navigationTitle("Ask about all of \(patient.name)'s sessions")
            } else {
                VStack(spacing: 10) {
                    Text("This patient is no longer available.")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.text.color)
                    Button("Close") { NSApp.keyWindow?.performClose(nil) }
                        .buttonStyle(.themed)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.window.color)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}
