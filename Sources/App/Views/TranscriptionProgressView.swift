import SwiftUI

/// What the Transcript tab shows while a session is being transcribed: the
/// stage, a determinate bar, a time estimate once there is enough data, and a
/// Cancel. `compact` is the one-line version shown above an existing transcript
/// (when re-transcribing) so the current text stays readable meanwhile.
struct TranscriptionProgressView: View {
    let job: TranscriptionJob
    var compact = false
    let onCancel: () -> Void

    private var percent: Int { Int(job.progress.fraction * 100) }

    /// "Transcribing call audio · about 2 min left", or the cancelling note.
    private var detail: String {
        if job.isCancelling { return "Cancelling… finishing the current step" }
        var parts = [job.progress.stage.title]
        if let remaining = job.remainingSeconds(now: Date()) {
            parts.append(TranscriptionProgressMath.remainingText(seconds: remaining))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if compact {
            banner
        } else {
            card
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Transcribing this session")
                .font(.title3)
            ProgressView(value: job.progress.fraction)
                .frame(maxWidth: 360)
            Text("\(percent)%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.callout)
            Text("Runs entirely on this Mac. You can leave this screen — transcription keeps going.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            cancelButton
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var banner: some View {
        HStack(spacing: 10) {
            ProgressView(value: job.progress.fraction)
                .frame(maxWidth: 200)
            Text("\(percent)% · \(detail)")
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 0)
            cancelButton
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel, action: onCancel)
            .disabled(!job.canCancel)
            .help("Stop transcribing. Nothing is saved and the recordings are kept.")
    }
}
