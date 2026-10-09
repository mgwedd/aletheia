import SwiftUI

/// The two live input meters on the recording panel: the therapist's own
/// microphone and the call audio. Observes only `RecordingLevels`, so the
/// frequent level updates redraw these bars and nothing else.
struct InputLevelMeters: View {
    @ObservedObject var levels: RecordingLevels
    var isPaused = false

    var body: some View {
        VStack(spacing: 14) {
            InputLevelMeter(label: "Your microphone", accessibilityName: "Your microphone level", level: levels.mic, fill: Theme.accent.color)
            InputLevelMeter(label: "Call audio", accessibilityName: "Call audio level", level: levels.call, fill: Theme.callAudio.color)
        }
        .frame(maxWidth: 440)
        .opacity(isPaused ? 0.5 : 1)
    }
}

/// One labelled level bar: an 8pt rounded track with a fill whose width is the
/// level (0...1).
private struct InputLevelMeter: View {
    let label: String
    let accessibilityName: String
    let level: Float
    let fill: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: CGFloat {
        CGFloat(min(1, max(0, level)))
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted.color)
                .frame(width: 96, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Theme.chip.color
                    fill
                        .frame(width: proxy.size.width * fraction)
                        .animation(reduceMotion ? nil : Animation.linear(duration: 0.08), value: fraction)
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
