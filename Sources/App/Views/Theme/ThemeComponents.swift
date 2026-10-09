import SwiftUI

// The design's shared controls, built on `Theme` tokens. Each one is a
// SwiftUI style or a small view, so it keeps native behaviour: keyboard
// activation, the disabled state, `.controlSize`, VoiceOver traits, and the
// appearance and Increase Contrast settings.

// MARK: - Buttons

/// The bordered button used across the workspace.
///
///   standard   raised fill, hairline border     Export, Transcribe, Save
///   primary    accent fill, accent ink          Send, Generate, Finish setup
///   recording  red fill, white ink              Stop recording
///
/// Disabled buttons drop their fill and use muted ink, as in the design.
struct ThemeButtonStyle: ButtonStyle {
    enum Kind { case standard, primary, recording }
    var kind: Kind = .standard

    func makeBody(configuration: Configuration) -> some View {
        ThemeButton(configuration: configuration, kind: kind)
    }
}

private struct ThemeButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: ThemeButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovered = false

    private var height: CGFloat {
        switch controlSize {
        case .mini: return 22
        case .small: return 28
        case .large, .extraLarge: return 40
        default: return 34
        }
    }

    private var horizontalPadding: CGFloat {
        switch controlSize {
        case .mini, .small: return 10
        case .large, .extraLarge: return 18
        default: return 12
        }
    }

    private var highlighted: Bool { isEnabled && (isHovered || configuration.isPressed) }

    private var fill: Color {
        switch kind {
        case .standard:
            guard isEnabled else { return .clear }
            return highlighted ? Theme.hover.color : Theme.raised.color
        case .primary:
            return highlighted ? Theme.accentHover.color : Theme.accent.color
        case .recording:
            return Theme.recordingFill.color
        }
    }

    private var border: Color {
        switch kind {
        case .standard: return Theme.line.color
        case .primary: return highlighted ? Theme.accentHover.color : Theme.accent.color
        case .recording: return Theme.recordingFill.color
        }
    }

    private var ink: Color {
        switch kind {
        case .standard: return isEnabled ? Theme.text.color : Theme.muted.color
        case .primary: return Theme.accentInk.color
        case .recording: return Theme.recordingInk.color
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        configuration.label
            .font(Theme.Typography.control)
            .lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: height)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            // A filled button that is disabled fades rather than vanishing, so
            // the call to action still reads as one.
            .opacity(kind != .standard && !isEnabled ? 0.45 : 1)
            .brightness(kind == .recording && configuration.isPressed ? -0.06 : 0)
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}

/// A borderless icon button (search, resolve, delete): muted until the
/// pointer is over it. Give the button a `Label` so VoiceOver has a name.
struct ThemeIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ThemeIconButton(configuration: configuration)
    }
}

private struct ThemeIconButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovered = false

    var body: some View {
        let side: CGFloat = controlSize == .small || controlSize == .mini ? 26 : 32
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        let active = isEnabled && (isHovered || configuration.isPressed)
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(active ? Theme.text.color : Theme.muted.color)
            .frame(width: side, height: side)
            .background(active ? Theme.hover.color : .clear, in: shape)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: active)
    }
}

extension ButtonStyle where Self == ThemeButtonStyle {
    /// `.buttonStyle(.themed)`
    static var themed: ThemeButtonStyle { ThemeButtonStyle() }
    /// `.buttonStyle(.themePrimary)`
    static var themePrimary: ThemeButtonStyle { ThemeButtonStyle(kind: .primary) }
    /// `.buttonStyle(.themeRecording)`
    static var themeRecording: ThemeButtonStyle { ThemeButtonStyle(kind: .recording) }
}

extension ButtonStyle where Self == ThemeIconButtonStyle {
    /// `.buttonStyle(.themeIcon)`
    static var themeIcon: ThemeIconButtonStyle { ThemeIconButtonStyle() }
}

// MARK: - Chip

/// A small capsule tag: a count, "Transcript", "AI draft", "Recording", or a
/// check result ("OK", "Warning", "Problem").
struct Chip: View {
    enum Tone { case neutral, accent, recording, ok, warn, info }

    let text: String
    var tone: Tone = .neutral
    /// A leading status dot (the live "Recording" badge).
    var showsDot = false

    init(_ text: String, tone: Tone = .neutral, showsDot: Bool = false) {
        self.text = text
        self.tone = tone
        self.showsDot = showsDot
    }

    private var fill: Color {
        switch tone {
        case .neutral: return Theme.chip.color
        case .accent: return Theme.accentTint.color
        case .recording: return Theme.recordingTint.color
        case .ok: return Theme.okTint.color
        case .warn: return Theme.warnTint.color
        case .info: return Theme.infoTint.color
        }
    }

    private var ink: Color {
        switch tone {
        case .neutral: return Theme.chipInk.color
        case .accent: return Theme.text.color
        case .recording: return Theme.recording.color
        case .ok: return Theme.ok.color
        case .warn: return Theme.warn.color
        case .info: return Theme.info.color
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if showsDot {
                Circle().fill(ink).frame(width: 6, height: 6)
            }
            Text(text)
                .font(Theme.Typography.chip)
                .lineLimit(1)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(fill, in: Capsule())
        .fixedSize()
    }
}

// MARK: - Filter chip

/// A toggleable capsule for filtering a list ("All 5", "Transcripts 2"). The
/// selected one takes the accent tint and an accent border.
struct ThemeFilterChipStyle: ButtonStyle {
    var isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        FilterChipBody(configuration: configuration, isOn: isOn)
    }

    private struct FilterChipBody: View {
        let configuration: ButtonStyleConfiguration
        let isOn: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            let fill: Color = isOn ? Theme.accentTint.color : (isHovered || configuration.isPressed ? Theme.hover.color : .clear)
            configuration.label
                .font(Theme.Typography.control)
                .lineLimit(1)
                .foregroundStyle(isEnabled ? Theme.text.color : Theme.muted.color)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(fill, in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? Theme.accent.color : Theme.line.color, lineWidth: 1))
                .contentShape(Capsule())
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .accessibilityAddTraits(isOn ? .isSelected : [])
        }
    }
}

extension ButtonStyle where Self == ThemeFilterChipStyle {
    /// `.buttonStyle(.themeFilterChip(isOn: filter == .all))`
    static func themeFilterChip(isOn: Bool) -> ThemeFilterChipStyle { ThemeFilterChipStyle(isOn: isOn) }
}

// MARK: - Key cap

/// A keyboard key in a hint ("esc", "↑", "⌘ return"). Decorative: give the
/// surrounding hint its own accessibility label.
struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Text(key)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.muted.color)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(Theme.field.color, in: shape)
            .overlay(shape.strokeBorder(Theme.line.color, lineWidth: 1))
            // The design's key cap has a heavier bottom edge.
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.line.color).frame(height: 1).padding(.horizontal, 3)
            }
            .fixedSize()
    }
}

// MARK: - Progress bar

/// A thin determinate bar: setup progress, transcription, passphrase strength.
struct ThemeProgressBar: View {
    /// 0...1; values outside are clamped.
    let value: Double
    var tint: Color = Theme.accent.color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.chip.color)
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((min(max(value, 0), 1) * 100).rounded())) percent"))
    }
}

// MARK: - Tab bar

/// One tab in an `UnderlineTabBar` or a `ThemeSegmentedControl`.
struct ThemeTab<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

/// Text tabs with an accent underline under the selected one; the underline
/// slides between tabs.
struct UnderlineTabBar<Value: Hashable>: View {
    let tabs: [ThemeTab<Value>]
    @Binding var selection: Value
    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 22) {
            ForEach(tabs) { tab in
                let isSelected = tab.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : Animation.snappy(duration: 0.22)) { selection = tab.value }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.text.color : Theme.muted.color)
                        .padding(.horizontal, 2)
                        .frame(height: 42)
                        .overlay(alignment: .bottom) {
                            if isSelected {
                                Rectangle()
                                    .fill(Theme.accent.color)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(TabButtonStyle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Unselected tabs brighten under the pointer.
private struct TabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBrighten(label: configuration.label)
    }

    private struct HoverBrighten<Label: View>: View {
        let label: Label
        @State private var isHovered = false
        var body: some View {
            label
                .brightness(isHovered ? 0.08 : 0)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Segmented control

/// The design's segmented control: a recessed track with the selected segment
/// raised, sliding between options.
struct ThemeSegmentedControl<Value: Hashable>: View {
    let options: [ThemeTab<Value>]
    @Binding var selection: Value
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : Animation.snappy(duration: 0.22)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(Theme.Typography.control)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Theme.text.color : Theme.muted.color)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Theme.raised.color)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(Theme.line.color)
                                    )
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.field.color, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .strokeBorder(Theme.line.color)
        )
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Surfaces

extension View {
    /// A text field or editor's box: field fill, hairline border, accent border
    /// while focused.
    func themeField(isFocused: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
        return background(Theme.field.color, in: shape)
            .overlay(shape.strokeBorder(isFocused ? Theme.accent.color : Theme.line.color, lineWidth: isFocused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    /// A card: panel fill with a hairline border, or an accent border when it
    /// is the one in focus (the selected comment).
    func themeCard(isEmphasized: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return background(Theme.panel.color, in: shape)
            .overlay(shape.strokeBorder(isEmphasized ? Theme.accent.color : Theme.line.color, lineWidth: 1))
    }

    /// A status banner: the tone's tint behind it and a border in the tone's
    /// ink. Body text on it uses `Theme.text` / `Theme.muted`.
    func themeBanner(_ tone: BannerTone) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(tone.tint, in: shape)
            .overlay(shape.strokeBorder(tone.ink, lineWidth: 1))
    }

    /// A full-width hairline between regions.
    func themeDivider(_ edge: VerticalEdge = .bottom) -> some View {
        overlay(alignment: edge == .top ? .top : .bottom) {
            Rectangle().fill(Theme.line.color).frame(height: 1)
        }
    }
}

/// The tone of a `themeBanner`.
enum BannerTone {
    case info, warn, danger

    var ink: Color {
        switch self {
        case .info: return Theme.info.color
        case .warn: return Theme.warn.color
        case .danger: return Theme.recording.color
        }
    }

    var tint: Color {
        switch self {
        case .info: return Theme.infoTint.color
        case .warn: return Theme.warnTint.color
        case .danger: return Theme.recordingTint.color
        }
    }
}
