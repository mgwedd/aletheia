import SwiftUI

/// A caption with a row of action buttons that never asks for more width than
/// it is given. A plain `HStack` of fixed-size buttons does: in a narrow pane
/// it widens the whole column (pushing the window toolbar off the edge) and
/// squeezes the caption to a word per line.
///
/// It picks the first arrangement that fits:
/// 1. caption, then the labelled buttons, on one line;
/// 2. caption on its own line, labelled buttons below;
/// 3. caption on its own line, icon-only buttons below. Each button keeps its
///    tooltip and its title as the accessibility label.
struct AdaptiveActionRow<Caption: View, Actions: View>: View {
    @ViewBuilder var caption: () -> Caption
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                caption()
                Spacer(minLength: 12)
                actionsRow
            }
            VStack(alignment: .leading, spacing: 8) {
                caption()
                actionsRow
            }
            VStack(alignment: .leading, spacing: 8) {
                caption()
                actionsRow
                    .labelStyle(.iconOnly)
                    .environment(\.compactActions, true)
            }
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 8) { actions() }
    }
}

private struct CompactActionsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True in `AdaptiveActionRow`'s narrowest arrangement, for controls that
    /// don't follow `.labelStyle` (a macOS `Menu` label).
    var compactActions: Bool {
        get { self[CompactActionsKey.self] }
        set { self[CompactActionsKey.self] = newValue }
    }
}

/// A label that shows only its icon in `AdaptiveActionRow`'s narrowest
/// arrangement, keeping the title for VoiceOver and the tooltip.
struct AdaptiveLabel: View {
    let title: String
    let systemImage: String
    @Environment(\.compactActions) private var compact

    var body: some View {
        if compact {
            Image(systemName: systemImage)
                .accessibilityLabel(title)
                .help(title)
        } else {
            Label(title, systemImage: systemImage)
        }
    }
}
