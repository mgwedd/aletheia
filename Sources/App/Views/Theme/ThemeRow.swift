import SwiftUI

// Row chrome shared by the patient list and the session list: an inset,
// rounded row that tints when selected and brightens under the pointer.

private struct ThemeListRowModifier: ViewModifier {
    let isSelected: Bool
    /// The surface the list sits on, repainted behind each row so the system's
    /// own selection highlight never shows through.
    let surface: Theme.ColorToken

    @State private var isHovered = false

    private static let inset: CGFloat = 8
    private static let gap: CGFloat = 1

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovered && !isSelected ? Theme.hover.color : .clear, in: shape)
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .padding(.horizontal, Self.inset)
            .padding(.vertical, Self.gap)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(
                ZStack {
                    surface.color
                    if isSelected {
                        shape
                            .fill(Theme.accentTint.color)
                            .padding(.horizontal, Self.inset)
                            .padding(.vertical, Self.gap)
                    }
                }
            )
    }
}

extension View {
    /// Styles a `List` row as a design row: 10pt radius, selected fill,
    /// pointer-over fill. Apply to the row's content, before `.tag(_:)`.
    func themeListRow(isSelected: Bool, surface: Theme.ColorToken) -> some View {
        modifier(ThemeListRowModifier(isSelected: isSelected, surface: surface))
    }
}
