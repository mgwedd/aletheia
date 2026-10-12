import SwiftUI

/// The call-audio triage readout shown on the recording screen when
/// Settings > "Show recording diagnostics" is on. Refreshes once a second.
struct CallAudioDebugView: View {
    @ObservedObject var recorder: SessionRecorder

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 3) {
                Text("Call audio diagnostics").eyebrowStyle()
                ForEach(recorder.callAudioDiagnostics().rows, id: \.label) { row in
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
