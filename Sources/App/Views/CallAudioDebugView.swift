import SwiftUI

/// The call-audio triage readout shown on the recording screen when
/// Settings > "Show recording diagnostics" is on. Refreshes once a second.
struct CallAudioDebugView: View {
    let enabled: Bool
    @ObservedObject var recorder: SessionRecorder

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let rows = RecordingDiagnostics.readout(enabled: enabled, current: { recorder.callAudioDiagnostics() }) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Call audio diagnostics").eyebrowStyle()
                ForEach(rows, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label)
                        Spacer(minLength: 12)
                        Text(row.value).multilineTextAlignment(.trailing)
                    }
                }
            }
            .font(Theme.Typography.caption.monospaced())
            .foregroundStyle(Theme.muted.color)
            .textSelection(.enabled)
            .frame(maxWidth: 440, alignment: .leading)
            }
        }
    }
}
