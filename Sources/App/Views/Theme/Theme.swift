import SwiftUI
import AppKit

/// The app's design tokens. Every color is a named color in the asset catalog
/// (`Assets.xcassets/Theme`), with a light and a dark value and, where it
/// matters, an Increase Contrast variant. That is the platform's own theming
/// mechanism, so:
///
/// - SwiftUI and AppKit resolve the same color (`color` / `nsColor`), and it
///   follows the window's effective appearance, the app's Light / Dark / System
///   setting (`AppearancePreference`) and Increase Contrast with no plumbing.
/// - A subtree forced to one appearance (`.environment(\.colorScheme, .light)`)
///   resolves correctly, which a code-defined dynamic color would not.
/// - The accent is the catalog's `AccentColor`, which is also the app's global
///   accent, so system controls (focus rings, toggles, links) match.
///
/// Screens take colors from here, never literals. `ThemeTests` resolves every
/// token in each appearance and checks the contrast contract below.
///
///   surfaces (back → front)              ink               states
///   window · sidebar · panel · field     text · muted      accent · accentTint
///   raised · hover · line                chipInk           highlight · recording
///                                                          bubble · callout · callAudio
///                                                          ok · warn · info (+ tints)
enum Theme {
    /// A named color from the asset catalog.
    struct ColorToken: Hashable {
        let name: String

        init(_ name: String) { self.name = name }

        var color: Color { Color(name, bundle: Theme.bundle) }

        /// For AppKit views (the transcript's `NSTextView`). A catalog color is
        /// dynamic, so it re-resolves when the appearance changes.
        var nsColor: NSColor {
            guard let color = NSColor(named: name, bundle: Theme.bundle) else {
                assertionFailure("Missing color \(name) in the asset catalog")
                return .labelColor
            }
            return color
        }
    }

    fileprivate final class BundleToken {}
    static let bundle = Bundle(for: BundleToken.self)

    // MARK: Surfaces

    /// The window: session header, tab bar, the comments rail.
    static let window = ColorToken("Theme/Window")
    /// The patient list.
    static let sidebar = ColorToken("Theme/Sidebar")
    /// Content panes: the patient column, the action bar, tab content.
    static let panel = ColorToken("Theme/Panel")
    /// Buttons and the selected segment.
    static let raised = ColorToken("Theme/Raised")
    /// Pointer-over fill for buttons and rows.
    static let hover = ColorToken("Theme/Hover")
    /// Hairlines and borders. Stronger under Increase Contrast.
    static let line = ColorToken("Theme/Line")
    /// Text fields and editors.
    static let field = ColorToken("Theme/Field")

    // MARK: Ink

    static let text = ColorToken("Theme/Text")
    /// Secondary text: captions, time stamps, metadata. Stronger under
    /// Increase Contrast.
    static let muted = ColorToken("Theme/Muted")

    // MARK: Accent and states

    /// Primary actions, the selected tab, the therapist's track.
    static let accent = ColorToken("AccentColor")
    /// Text and icons on an accent fill.
    static let accentInk = ColorToken("Theme/AccentInk")
    static let accentHover = ColorToken("Theme/AccentHover")
    /// The selected row, and the "AI draft" tag.
    static let accentTint = ColorToken("Theme/AccentTint")
    /// Small tags and counts.
    static let chip = ColorToken("Theme/Chip")
    static let chipInk = ColorToken("Theme/ChipInk")
    /// Commented text in the transcript.
    static let highlight = ColorToken("Theme/Highlight")
    static let highlightInk = ColorToken("Theme/HighlightInk")
    /// Recording state: the timer, the live badge.
    static let recording = ColorToken("Theme/Recording")
    /// The Stop button's fill, with `recordingInk` on it.
    static let recordingFill = ColorToken("Theme/RecordingFill")
    static let recordingInk = ColorToken("Theme/RecordingInk")
    /// Behind the "Recording" badge.
    static let recordingTint = ColorToken("Theme/RecordingTint")
    /// The therapist's own message in Ask.
    static let bubble = ColorToken("Theme/Bubble")
    /// Informational callouts, such as the AI-draft notice.
    static let callout = ColorToken("Theme/Callout")
    /// Call audio, the second track wherever two are shown.
    static let callAudio = ColorToken("Theme/CallAudio")

    // MARK: Status

    // Check results, banners and status chips. Each ink reads on its own tint;
    // the danger pair is `recording` / `recordingTint`.
    //
    //   ok    "OK", "On", "Installed"         okTint behind it
    //   warn  "Warning", "Off", "Unreadable"  warnTint behind it
    //   info  Time Machine, transcription     infoTint behind it

    static let ok = ColorToken("Theme/Ok")
    static let okTint = ColorToken("Theme/OkTint")
    static let warn = ColorToken("Theme/Warn")
    static let warnTint = ColorToken("Theme/WarnTint")
    static let info = ColorToken("Theme/Info")
    static let infoTint = ColorToken("Theme/InfoTint")

    static let all: [ColorToken] = [
        window, sidebar, panel, raised, hover, line, field,
        text, muted,
        accent, accentInk, accentHover, accentTint, chip, chipInk,
        highlight, highlightInk, recording, recordingFill, recordingInk, recordingTint,
        bubble, callout, callAudio,
        ok, okTint, warn, warnTint, info, infoTint,
    ]

    // MARK: Contrast contract

    /// A foreground drawn on a background and the least contrast it may have:
    /// WCAG AA, 4.5:1 for text and 3:1 for borders that carry meaning.
    /// `ThemeTests` checks every pair in light, dark and both Increase Contrast
    /// appearances, so a palette change that hurts legibility fails CI.
    struct Pairing {
        let foreground: ColorToken
        let background: ColorToken
        let minimum: Double
        /// Only enforced under Increase Contrast (the default hairlines are
        /// deliberately quiet).
        var highContrastOnly = false
    }

    static let pairings: [Pairing] = {
        var pairs: [Pairing] = []
        for surface in [window, sidebar, panel, raised, hover, field, accentTint, bubble, callout, chip] {
            pairs.append(Pairing(foreground: text, background: surface, minimum: 4.5))
        }
        for surface in [window, sidebar, panel, raised, hover, field, callout] {
            pairs.append(Pairing(foreground: muted, background: surface, minimum: 4.5))
        }
        for surface in [window, panel, field] {
            pairs.append(Pairing(foreground: accent, background: surface, minimum: 4.5))
            pairs.append(Pairing(foreground: callAudio, background: surface, minimum: 4.5))
            pairs.append(Pairing(foreground: recording, background: surface, minimum: 4.5))
            pairs.append(Pairing(foreground: line, background: surface, minimum: 3, highContrastOnly: true))
        }
        pairs += [
            Pairing(foreground: accentInk, background: accent, minimum: 4.5),
            Pairing(foreground: accentInk, background: accentHover, minimum: 4.5),
            Pairing(foreground: chipInk, background: chip, minimum: 4.5),
            Pairing(foreground: highlightInk, background: highlight, minimum: 4.5),
            Pairing(foreground: recording, background: recordingTint, minimum: 4.5),
            // Error and warning banners, the Doctor database card, and the
            // compact transcription banner put body and secondary text on these.
            Pairing(foreground: text, background: recordingTint, minimum: 4.5),
            Pairing(foreground: muted, background: recordingTint, minimum: 4.5),
            Pairing(foreground: callAudio, background: callout, minimum: 4.5),
            Pairing(foreground: muted, background: chip, minimum: 4.5),
            Pairing(foreground: recordingInk, background: recordingFill, minimum: 4.5),
        ]
        // Status chips and banners: the ink on its tint, and body and
        // secondary text inside a tinted banner.
        for (ink, tint) in [(ok, okTint), (warn, warnTint), (info, infoTint)] {
            pairs.append(Pairing(foreground: ink, background: tint, minimum: 4.5))
            pairs.append(Pairing(foreground: text, background: tint, minimum: 4.5))
            pairs.append(Pairing(foreground: muted, background: tint, minimum: 4.5))
        }
        for surface in [window, panel, field] {
            for ink in [ok, warn, info] {
                pairs.append(Pairing(foreground: ink, background: surface, minimum: 4.5))
            }
        }
        return pairs
    }()

    // MARK: Type

    /// Display type is the system serif (New York), which gives titles and the
    /// drafted note an editorial feel with no font to bundle. Interface text is
    /// the system font. Sizes follow the design; line spacing is the extra
    /// leading the design's line heights call for.
    enum Typography {
        /// Setup's title.
        static let display = Font.system(size: 34, weight: .regular, design: .serif)
        /// The recording timer.
        static let timer = Font.system(size: 72, weight: .regular, design: .serif).monospacedDigit()
        /// The patient's name.
        static let title = Font.system(size: 24, weight: .regular, design: .serif)
        /// The session date in its header.
        static let headline = Font.system(size: 16, weight: .semibold)
        static let body = Font.system(size: 14)
        /// Transcript and chat answers.
        static let reading = Font.system(size: 15)
        static let readingLineSpacing: CGFloat = 5
        /// The drafted note.
        static let noteBody = Font.system(size: 16, design: .serif)
        static let noteHeading = Font.system(size: 20, weight: .medium, design: .serif)
        static let noteLineSpacing: CGFloat = 6
        static let control = Font.system(size: 13, weight: .medium)
        static let caption = Font.system(size: 12)
        /// A small uppercase label above a region ("SESSIONS", "COMMENTS").
        static let sectionLabel = Font.system(size: 11, weight: .semibold)
        static let chip = Font.system(size: 11, weight: .semibold)
    }

    /// Corner radii, shared so nested shapes stay concentric.
    enum Radius {
        static let control: CGFloat = 8
        static let field: CGFloat = 10
        static let card: CGFloat = 12
    }
}

extension View {
    /// An uppercase, letter-spaced region label.
    func eyebrowStyle() -> some View {
        font(Theme.Typography.sectionLabel)
            .textCase(.uppercase)
            .tracking(0.66)
            .foregroundStyle(Theme.muted.color)
            .accessibilityAddTraits(.isHeader)
    }
}
