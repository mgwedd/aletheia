import SwiftUI

/// The Keyboard Shortcuts window: every shortcut the app defines, from
/// `ShortcutCatalog`, so the list can't drift from the keys that are bound.
struct ShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(ShortcutCatalog.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title).eyebrowStyle()
                        VStack(spacing: 0) {
                            ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { Divider().overlay(Theme.line.color) }
                                row(entry)
                            }
                        }
                        .themeCard()
                    }
                }
            }
            .padding(24)
        }
        .background(Theme.window.color)
        .frame(minWidth: 400, minHeight: 360)
    }

    private func row(_ entry: ShortcutEntry) -> some View {
        HStack(spacing: 12) {
            Text(entry.title)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.text.color)
            Spacer(minLength: 12)
            ShortcutHint(entry.shortcut)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}
