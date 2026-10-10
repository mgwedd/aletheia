import AppKit
import SwiftUI

/// The numbered, failure-specific diagnosing steps for a database that won't
/// open, plus a button to reveal the data folder. Shared by the main-window
/// banner and the Doctor window so both say exactly the same thing.
struct DatabaseGuidanceView: View {
    let guidance: DatabaseGuidance
    let failure: DatabaseOpenFailure
    let dataFolder: URL?
    /// The banner already shows the explanation above its buttons, so it turns
    /// this off to avoid saying it twice; the Doctor window keeps the default.
    var showsExplanation = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsExplanation {
                Text(guidance.explanation)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

/// The unmissable error card shown across the top of the main window when the
/// database couldn't be opened: a round red database mark, the headline in the
/// serif title face, the plain-words explanation, and the actions. Notes and
/// chat can't be saved until it's fixed, so it must never be silent — but the
/// app stays usable for reading transcripts and summaries, so it's a card above
/// the content, not a modal.
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
        HStack(alignment: .top, spacing: 20) {
            ZStack {
                Circle().fill(Theme.recordingTint.color)
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Theme.recording.color)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(guidance.headline)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(guidance.explanation)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button(showSteps ? "Hide Steps" : "Show Steps") {
                        withAnimation(.easeOut(duration: 0.15)) { showSteps.toggle() }
                    }
                    .buttonStyle(.themed)
                    if showDoctorButton {
                        Button("Open Aletheia Doctor…", action: onOpenDoctor)
                            .buttonStyle(.plain)
                            .font(Theme.Typography.control)
                            .foregroundStyle(Theme.muted.color)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 34)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.top, 2)
                if showSteps {
                    ScrollView {
                        DatabaseGuidanceView(
                            guidance: guidance,
                            failure: failure,
                            dataFolder: dataFolder,
                            showsExplanation: false
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                } else {
                    Text(guidance.shortNextStep)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
        .padding(12)
        .background(Theme.window.color)
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
