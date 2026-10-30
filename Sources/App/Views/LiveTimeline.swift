import SwiftUI

/// A live clock for elapsed counters: redraws `content` every `interval`
/// seconds with the time to show. In a fixture run (the Debug app under UI
/// tests) nothing ticks: `content` is drawn with the real now whenever the
/// view redraws for a change of state, so the text is right as of each change
/// and the window is not redrawn every second while tests wait on it.
struct LiveTimeline<Content: View>: View {
    var interval: TimeInterval = 1
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if QuietUI.isOn {
            content(Date())
        } else {
            TimelineView(.periodic(from: .now, by: interval)) { context in
                content(context.date)
            }
        }
    }
}

/// Whether the UI holds still: only in a fixture run, never in a shipped build.
enum QuietUI {
    static var isOn: Bool {
        #if DEBUG
        FixtureMode.isActive
        #else
        false
        #endif
    }

    /// Reduce Motion as the screen should honour it: always on in a fixture run.
    static func reducesMotion(_ systemSetting: Bool) -> Bool { systemSetting || isOn }
}
