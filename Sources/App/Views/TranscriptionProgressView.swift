import SwiftUI

/// What the Transcript tab shows while a session is being transcribed: an
/// info-tinted band across the top with a spinner, the title, a determinate
/// bar, the percentage and (once there is enough data) a time estimate, what
/// is happening now, and a Cancel. `compact` is shown above an existing
/// transcript (when re-transcribing) so the current text stays readable
/// meanwhile; otherwise the band sits at the top of an otherwise empty tab.
struct TranscriptionProgressView: View {
    let job: TranscriptionJob
    var compact = false
    /// The session's own date, for the title ("Transcribing Oct 8, 2:14 PM").
    /// Without it the title reads "Transcribing this session".
    var sessionDate: Date? = nil
    let onCancel: () -> Void

    private var percent: Int { Int(job.progress.fraction * 100) }

    private var title: String {
        guard let sessionDate else { return "Transcribing this session" }
        return "Transcribing \(sessionDate.formatted(date: .abbreviated, time: .shortened))"
    }

    /// "42% · about 2 min left"; the estimate only appears once the model has one.
    private var progressText: String {
        var parts = ["\(percent)%"]
        if let remaining = job.remainingSeconds(now: Date()) {
            parts.append(TranscriptionProgressMath.remainingText(seconds: remaining))
        }
        return parts.joined(separator: " · ")
    }

    /// The current stage plus the standing reassurance, or the cancelling note.
    private var detail: String {
        if job.isCancelling { return "Cancelling… finishing the current step" }
        return "\(job.progress.stage.title). Runs entirely on this Mac. You can leave this screen — transcription keeps going."
    }

    var body: some View {
        if compact {
            band
        } else {
            VStack(spacing: 0) {
                band
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var band: some View {
        HStack(spacing: 16) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.info.color)
                .accessibilityLabel("Transcribing")
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(title)
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.text.color)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(progressText)
                        .font(Theme.Typography.control.monospacedDigit())
                        .foregroundStyle(Theme.muted.color)
                        .lineLimit(1)
                }
                ThemeProgressBar(value: job.progress.fraction, tint: Theme.info.color)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            cancelButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.infoTint.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.info.color).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel, action: onCancel)
            .buttonStyle(.themed)
            .disabled(!job.canCancel)
            .help("Stop transcribing. Nothing is saved and the recordings are kept.")
    }
}
