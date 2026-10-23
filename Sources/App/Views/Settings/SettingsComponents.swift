import SwiftUI

// The Settings window's chrome and row kit: a sidebar of panes, a header bar,
// and the card/row pieces each pane is built from. Colors come from `Theme`.

// MARK: - Panes

/// The sections of Settings, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case ai
    case format
    case encryption
    case backups
    case security
    case license
    case setAsideRecordings

    static let `default`: SettingsPane = .general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .ai: return "AI and models"
        case .format: return "Note format"
        case .encryption: return "Encryption"
        case .backups: return "Backups"
        case .security: return "Security"
        case .license: return "License"
        case .setAsideRecordings: return "Set-aside recordings"
        }
    }

    /// The panes this build shows. Encryption is left out when there is nothing
    /// to manage (see `SettingsAvailability`) rather than shown as unavailable.
    /// Set-aside recordings shows only while there are some.
    static func available(encryptionOffered: Bool, hasSetAsideRecordings: Bool = false) -> [SettingsPane] {
        allCases.filter {
            switch $0 {
            case .encryption: return encryptionOffered
            case .setAsideRecordings: return hasSetAsideRecordings
            default: return true
            }
        }
    }

    /// The pane for a remembered raw value: the default when it is unknown or
    /// not among `panes` (a pane this build no longer shows).
    static func restored(rawValue: String, in panes: [SettingsPane]) -> SettingsPane {
        guard let pane = SettingsPane(rawValue: rawValue), panes.contains(pane) else { return .default }
        return pane
    }

    /// The pane `delta` rows away among `panes` (clamped at either end), for up / down.
    func moved(by delta: Int, in panes: [SettingsPane] = SettingsPane.allCases) -> SettingsPane {
        guard let index = panes.firstIndex(of: self) else { return panes.first ?? self }
        return panes[min(max(index + delta, 0), panes.count - 1)]
    }
}

/// What Settings offers depends on what the build ships. Controls for a feature
/// the build does not have are left out, not shown as unavailable.
enum SettingsAvailability {
    /// Encryption is offered when this build includes it, or when a folder is
    /// already encrypted (by this build or an earlier one), so it can still be
    /// unlocked and managed.
    static func encryptionOffered(isEnabled: Bool, moduleInBuild: Bool) -> Bool {
        isEnabled || moduleInBuild
    }

    /// Keeping raw audio needs encryption (kept audio must be ciphertext), so
    /// without it the switch could never be turned on.
    static func showsKeepAudio(encryptionOffered: Bool) -> Bool {
        encryptionOffered
    }
}

// MARK: - Sidebar

/// The left column: one button per pane, the selected one on the accent tint.
/// Up / down arrows move the selection while a row has keyboard focus.
/// Settings window geometry, in one place. `SettingsView` declares its own
/// minimum size from these; presenters (the sheet, the Settings scene) must not
/// wrap it in a smaller `.frame(minWidth:)`, which clips the content instead of
/// growing the window.
enum SettingsLayout {
    static let sidebarWidth: CGFloat = 220
    /// Narrowest a pane's controls (field + button, segmented control) fit.
    static let paneMinWidth: CGFloat = 680
    static let minWidth: CGFloat = sidebarWidth + paneMinWidth
    static let idealWidth: CGFloat = 960
    static let minHeight: CGFloat = 640
    static let idealHeight: CGFloat = 680
}

struct SettingsSidebar: View {
    @Binding var selection: SettingsPane
    var panes: [SettingsPane] = SettingsPane.allCases

    var body: some View {
        VStack(spacing: 2) {
            ForEach(panes) { pane in
                SettingsSidebarRow(pane: pane, isSelected: pane == selection) {
                    selection = pane
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .frame(width: SettingsLayout.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar.color)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.line.color).frame(width: 1)
        }
        .onMoveCommand { direction in
            switch direction {
            case .up: selection = selection.moved(by: -1, in: panes)
            case .down: selection = selection.moved(by: 1, in: panes)
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }
}

private struct SettingsSidebarRow: View {
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            Text(pane.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text.color)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(rowFill, in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        // The selected fill marks the row; a focus ring would sit on the first
        // row the sheet focused, not the selected one.
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowFill: Color {
        if isSelected { return Theme.accentTint.color }
        return isHovered ? Theme.hover.color : .clear
    }
}

// MARK: - Header and scrolling pane

/// The right-hand column: a 52pt header bar with the pane title and a hairline,
/// then the pane's content in a scroll view with 28pt gutters.
struct SettingsPaneContainer<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.text.color)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 28)
            .frame(height: 52)
            .themeDivider(.bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content()
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel.color)
    }
}

// MARK: - Cards and rows

/// A full-width hairline between rows.
struct SettingsHairline: View {
    var body: some View {
        Rectangle().fill(Theme.line.color).frame(height: 1)
    }
}

/// A bordered card with 16pt padding around its content.
struct SettingsCard<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }
}

/// A card of `SettingsRow`s: 16pt side padding, rows separated by
/// `SettingsHairline`s. Give each row `.padding(.vertical, 12)`.
struct SettingsRowsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }
}

/// A card header: an eyebrow label with an optional status chip at the right.
struct SettingsCardHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(title).eyebrowStyle()
            Spacer(minLength: 12)
            trailing()
        }
    }
}

/// A setting: title (14pt) over a muted 12pt detail, with the control at the
/// trailing edge. A row whose explanation is a "how this works" aside takes
/// it as `tip` instead of `detail`: shown on hover, not in the layout.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var tip: HelpTip?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        if let tip {
            row.hoverTip(tip)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.body.weight(.medium))
                    .foregroundStyle(Theme.text.color)
                if let detail {
                    Text(detail)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.muted.color)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            trailing()
        }
    }
}

/// A `SettingsRow` whose control is a native switch.
struct SettingsSwitchRow: View {
    let title: String
    var detail: String?
    var tip: HelpTip?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, detail: detail, tip: tip) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent.color)
        }
    }
}

/// A muted 12pt explanatory line.
struct SettingsCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.muted.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
