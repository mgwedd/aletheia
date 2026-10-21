import SwiftUI

/// The same band for a session waiting its turn behind another transcription.
struct TranscriptionQueuedView: View {
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "clock")
                .foregroundStyle(Theme.info.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Waiting to transcribe")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.text.color)
                Text("Another session is being transcribed. This one starts by itself when that finishes — you can leave this screen.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.themed)
                .help("Take this session out of the queue. The recordings are kept.")
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
}

/// What the session screen shows above every tab while the session is being
/// transcribed: an info-tinted band with a spinner, the title, a determinate
/// bar, the percentage and (once there is enough data) a time estimate, what
/// is happening now, and a Cancel.
struct TranscriptionProgressView: View {
    let job: TranscriptionJob
    /// The session's own date, for the title ("Transcribing Oct 8, 2:14 PM").
    /// Without it the title reads "Transcribing this session".
    var sessionDate: Date? = nil
    let onCancel: () -> Void

    private var percent: Int { Int(job.progress.fraction * 100) }

    private var title: String {
        let base = sessionDate.map { "Transcribing \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Transcribing this session"
        if let model = job.modelName, !model.isEmpty {
            return "\(base) · \(model)"
        }
        return base
    }

    /// "42% · about 2 min left"; the estimate only appears once the model has one.
    private var progressText: String {
        var parts = ["\(percent)%"]
        if let remaining = job.remainingSeconds(now: Date()) {
            parts.append(TranscriptionProgressMath.remainingText(seconds: remaining))
        }
        return parts.joined(separator: " · ")
    }

    /// The current stage and a note that it keeps going, or the cancelling note.
    private var detail: String {
        if job.isCancelling { return "Cancelling… finishing the current step" }
        return "\(job.progress.stage.title). You can leave this screen — transcription keeps going."
    }

    var body: some View {
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
