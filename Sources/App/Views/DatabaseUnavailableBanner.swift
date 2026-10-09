import AppKit
import SwiftUI

/// The numbered, failure-specific diagnosing steps for a database that won't
/// open, plus a button to reveal the data folder. Shared by the main-window
/// banner and the Doctor window so both say exactly the same thing.
struct DatabaseGuidanceView: View {
    let guidance: DatabaseGuidance
    let failure: DatabaseOpenFailure
    let dataFolder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(guidance.explanation)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.text.color)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(guidance.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).")
                            .font(Theme.Typography.body.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Theme.text.color)
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(step)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.text.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }

            HStack(spacing: 10) {
                if let dataFolder {
                    Button("Show Data Folder in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([dataFolder])
                    }
                    .buttonStyle(.themed)
                    .controlSize(.small)
                }
                Text("Technical detail: \(failure.reason)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The unmissable, non-blocking error strip shown across the top of the main
/// window when the database couldn't be opened. Notes and chat can't be saved
/// until it's fixed, so it must never be silent — but the app stays usable for
/// reading transcripts and summaries, so it's a banner, not a modal.
struct DatabaseUnavailableBanner: View {
    let failure: DatabaseOpenFailure
    let dataFolder: URL?
    let showDoctorButton: Bool
    let onOpenDoctor: () -> Void

    @State private var showSteps = true

    private var guidance: DatabaseGuidance {
        DatabaseFailureGuidance.guidance(for: failure, dataFolder: dataFolder?.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(Theme.recording.color)
                Text(guidance.headline)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.text.color)
                Spacer()
                Button(showSteps ? "Hide Steps" : "Show Steps") {
                    withAnimation { showSteps.toggle() }
                }
                .buttonStyle(.themed)
                .controlSize(.small)
                if showDoctorButton {
                    Button("Open Aletheia Doctor…", action: onOpenDoctor)
                        .buttonStyle(.themed)
                        .controlSize(.small)
                }
            }
            if showSteps {
                ScrollView {
                    DatabaseGuidanceView(guidance: guidance, failure: failure, dataFolder: dataFolder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            } else {
                Text(guidance.shortNextStep)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.recordingTint.color)
        .themeDivider(.bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: \(guidance.headline)")
    }
}

/// A small inline notice for a single failed save (chat or note) when the
/// database itself is open — disk full, file locked. The text the therapist
/// typed is still on screen; this just makes sure the failure isn't silent.
struct SaveFailureStrip: View {
    let subject: String
    let showDoctorButton: Bool
    let onOpenDoctor: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.callAudio.color)
            Text("Couldn't save your \(subject). It's still on screen — copy anything you need, then check the disk isn't full.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.text.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if showDoctorButton {
                Button("Open Aletheia Doctor…", action: onOpenDoctor)
                    .buttonStyle(.themed)
                    .controlSize(.small)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.callout.color)
        .themeDivider(.bottom)
    }
}
