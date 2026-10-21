import SwiftUI

/// How far one patient's background summaries have got, e.g. "Summaries: 62 of
/// 100 ready · paused on battery", with the one control that fits (Pause,
/// Resume or Prepare now). Hidden when the patient needs no summaries: then
/// every question reads the transcripts whole.
struct SummaryStatusRow: View {
    @ObservedObject var scheduler: DigestScheduler
    let patientID: UUID

    var body: some View {
        if let status = scheduler.status(for: patientID) {
            HStack(spacing: 8) {
                Text(status.text)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = status.action {
                    Button(action.title) {
                        scheduler.perform(action, patientID: patientID)
                    }
                    .buttonStyle(.themed)
                    .controlSize(.small)
                }
            }
            .help("Summaries let questions about this patient cover sessions too long to read whole. They are prepared on this Mac while the AI isn't doing anything else, and pause during recording and transcription.")
        }
    }
}
