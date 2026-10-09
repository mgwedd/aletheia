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
        }
    }

    /// The pane `delta` rows away (clamped at either end), for up / down.
    func moved(by delta: Int) -> SettingsPane {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return self }
        return all[min(max(index + delta, 0), all.count - 1)]
    }
}

// MARK: - Sidebar

/// The left column: one button per pane, the selected one on the accent tint.
/// Up / down arrows move the selection while a row has keyboard focus.
struct SettingsSidebar: View {
    @Binding var selection: SettingsPane

    var body: some View {
        VStack(spacing: 2) {
            ForEach(SettingsPane.allCases) { pane in
                SettingsSidebarRow(pane: pane, isSelected: pane == selection) {
                    selection = pane
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar.color)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.line.color).frame(width: 1)
        }
        .onMoveCommand { direction in
            switch direction {
            case .up: selection = selection.moved(by: -1)
            case .down: selection = selection.moved(by: 1)
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
/// trailing edge.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
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
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, detail: detail) {
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
