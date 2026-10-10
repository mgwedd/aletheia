import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Colours for drawing a diagram, all from `Theme`. They are catalog colors, so
/// `Canvas` resolves them against the environment each time it draws: on screen
/// they follow Light / Dark / Increase Contrast with no extra plumbing, and the
/// PNG export (which forces a light environment) gets the light values.
struct MermaidPalette {
    var nodeFill: Color
    var nodeStroke: Color
    var text: Color
    var edge: Color
    var labelFill: Color
    var labelText: Color
    var lifeline: Color

    static let adaptive = MermaidPalette(
        nodeFill: Theme.raised.color,
        nodeStroke: Theme.line.color,
        text: Theme.text.color,
        edge: Theme.muted.color,
        // Edge labels sit on the diagram card, which is a `Theme.field` surface.
        labelFill: Theme.field.color,
        labelText: Theme.text.color,
        lifeline: Theme.muted.color.opacity(0.5)
    )
}

/// Draws a `MermaidLayout` with `Canvas`. The layout's own coordinates are
/// scaled to whatever size the view is given, so it shrinks to fit a narrow chat
/// column without re-laying-out.
struct MermaidCanvas: View {
    let layout: MermaidLayout
    let palette: MermaidPalette

    var body: some View {
        Canvas { context, size in
            let scale = layout.size.width > 0 ? size.width / layout.size.width : 1
            context.scaleBy(x: scale, y: scale)
            MermaidPainter.draw(layout, palette: palette, in: &context)
        }
    }
}

/// A laid-out diagram, scaled down to the available width. If that would make
/// the text too small to read, it keeps its natural size inside a horizontal
/// scroll view instead.
struct MermaidDiagramView: View {
    let layout: MermaidLayout
    /// Short plain-language description for VoiceOver.
    let summary: String
    /// How far past its natural size the diagram may grow. 1 keeps the inline
    /// look; the expanded sheet passes a larger value to fill its width.
    var maxScale: CGFloat = 1

    @State private var availableWidth: CGFloat = 0

    /// Below this scale the text gets too small, so scroll instead of shrinking.
    private let minimumScale: CGFloat = 0.55

    var body: some View {
        let natural = layout.size
        if natural.width <= 0 || natural.height <= 0 {
            EmptyView()
        } else {
            let scale = availableWidth > 0 ? availableWidth / natural.width : 1
            Group {
                if scale >= minimumScale {
                    MermaidCanvas(layout: layout, palette: .adaptive)
                        .aspectRatio(natural, contentMode: .fit)
                        .frame(maxWidth: natural.width * max(maxScale, 1))
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        MermaidCanvas(layout: layout, palette: .adaptive)
                            .frame(width: natural.width, height: natural.height)
                    }
                    .frame(height: natural.height + 12)
                }
            }
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: MermaidWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(MermaidWidthKey.self) { availableWidth = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
        }
    }
}

private struct MermaidWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Card

/// Where a diagram card appears; it decides the caption under the card and
/// whether the card offers Expand.
enum MermaidCardContext {
    case ask
    case note

    var caption: String {
        switch self {
        case .ask:
            return "Drawn by the on-device model from this session. Check it against the transcript."
        case .note:
            return "Diagrams are kept in the note as text. Copy and Export include the Mermaid source."
        }
    }
}

/// A Mermaid block as a card: a header with the chip, a Diagram / Source toggle
/// and icon buttons, then the drawn diagram or the monospaced source, with a
/// muted caption under it.
///
///   ┌────────────────────────────────────────────────┐
///   │ (Mermaid diagram)      [Diagram|Source]  ⧉  ⤢  │
///   ├────────────────────────────────────────────────┤
///   │                  rendered diagram              │
///   └────────────────────────────────────────────────┘
///    caption
///
/// With no `diagram` (unsupported type, malformed, or still streaming in) the
/// card shows the source only, with no toggle and no error text.
struct MermaidCard: View {
    private enum Mode: Hashable { case diagram, source }

    let source: String
    let diagram: MermaidDiagram?
    let context: MermaidCardContext

    @State private var mode: Mode = .diagram
    @State private var copied = false
    @State private var isExpanded = false

    var body: some View {
        // Cached by source, so a streaming re-render doesn't redo the layout.
        let layout = diagram.map { MermaidDiagram.cachedLayout(for: source, diagram: $0) }
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                header(layout)
                Rectangle().fill(Theme.line.color).frame(height: 1)
                content(layout)
            }
            .background(Theme.field.color)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.line.color, lineWidth: 1)
            )

            Text(context.caption)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $isExpanded) {
            if let layout, let diagram {
                MermaidExpandedSheet(source: source, layout: layout, summary: diagram.accessibilityDescription)
            }
        }
    }

    private func header(_ layout: MermaidLayout?) -> some View {
        HStack(spacing: 6) {
            Chip("Mermaid diagram")
            Spacer(minLength: 8)
            if layout != nil {
                ThemeSegmentedControl(
                    options: [
                        ThemeTab(value: Mode.diagram, title: "Diagram"),
                        ThemeTab(value: Mode.source, title: "Source")
                    ],
                    selection: $mode
                )
                .frame(width: 160)
            }
            CopyMenu(source: source, layout: layout, copied: $copied)
            if context == .ask, layout != nil {
                Button {
                    isExpanded = true
                } label: {
                    Label("Expand diagram", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.themeIcon)
                .controlSize(.small)
                .help("Open a larger view of the diagram")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func content(_ layout: MermaidLayout?) -> some View {
        if let layout, let diagram, mode == .diagram {
            MermaidDiagramView(layout: layout, summary: diagram.accessibilityDescription)
                .padding(14)
        } else {
            MermaidSourceText(source: source)
        }
    }
}

/// The Mermaid text in a monospaced block that scrolls sideways rather than
/// wrapping, so indentation stays readable.
private struct MermaidSourceText: View {
    let source: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(source.isEmpty ? " " : source)
                .font(.system(size: 12.5, design: .monospaced))
                .lineSpacing(5)
                .foregroundStyle(Theme.text.color)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The Copy icon. Its main action copies a picture of the diagram (with the
/// source alongside as text for plain-text editors); the menu also offers the
/// source alone. With no drawn diagram it just copies the source.
private struct CopyMenu: View {
    let source: String
    let layout: MermaidLayout?
    @Binding var copied: Bool

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Menu {
            if layout != nil {
                Button("Copy diagram as picture") { copyPicture() }
            }
            Button("Copy Mermaid source") { copySource() }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isHovered ? Theme.text.color : Theme.muted.color)
                .frame(width: 26, height: 26)
                .background(isHovered ? Theme.hover.color : .clear, in: shape)
                .contentShape(shape)
        } primaryAction: {
            if layout != nil { copyPicture() } else { copySource() }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(layout != nil
              ? "Copies a picture of the diagram, and its source as text for plain-text editors"
              : "Copy the Mermaid source")
        .accessibilityLabel(copied ? "Copied" : "Copy diagram")
    }

    // Button actions run on the main thread; `assumeIsolated` states that for
    // the main-actor pasteboard helpers without making the whole view main-actor.
    private func copyPicture() {
        guard let layout else { return }
        let source = self.source
        MainActor.assumeIsolated {
            MermaidPasteboard.copyDiagram(layout: layout, source: source)
        }
        flashCopied()
    }

    private func copySource() {
        let source = self.source
        MainActor.assumeIsolated {
            MermaidPasteboard.copySource(source)
        }
        flashCopied()
    }

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

/// The Expand sheet: the same diagram, scaled up to the sheet's width, with a
/// Diagram / Source toggle and Copy.
private struct MermaidExpandedSheet: View {
    private enum Mode: Hashable { case diagram, source }

    let source: String
    let layout: MermaidLayout
    let summary: String

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .diagram
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Chip("Mermaid diagram")
                Spacer(minLength: 8)
                ThemeSegmentedControl(
                    options: [
                        ThemeTab(value: Mode.diagram, title: "Diagram"),
                        ThemeTab(value: Mode.source, title: "Source")
                    ],
                    selection: $mode
                )
                .frame(width: 160)
                CopyMenu(source: source, layout: layout, copied: $copied)
                Button("Done") { dismiss() }
                    .buttonStyle(.themePrimary)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .themeDivider(.bottom)

            ScrollView([.vertical]) {
                if mode == .diagram {
                    MermaidDiagramView(layout: layout, summary: summary, maxScale: 2.5)
                        .padding(24)
                } else {
                    MermaidSourceText(source: source)
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 620)
        .background(Theme.field.color)
        .onExitCommand { dismiss() }
    }
}

// MARK: - Painter

/// The drawing routines, kept apart from the views so on-screen rendering and
/// the PNG export share exactly the same code.
enum MermaidPainter {
    private typealias Metrics = MermaidLayout.Metrics

    static func draw(_ layout: MermaidLayout, palette: MermaidPalette, in context: inout GraphicsContext) {
        for line in layout.lifelines {
            var path = Path()
            path.move(to: CGPoint(x: line.x, y: line.top))
            path.addLine(to: CGPoint(x: line.x, y: line.bottom))
            context.stroke(path, with: .color(palette.lifeline),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        for edge in layout.edges {
            drawEdge(edge, palette: palette, in: &context)
        }
        for node in layout.nodes {
            let path = shapePath(node.shape, in: node.frame)
            context.fill(path, with: .color(palette.nodeFill))
            context.stroke(path, with: .color(palette.nodeStroke), lineWidth: 1.5)
            drawLines(node.lines, center: CGPoint(x: node.frame.midX, y: node.frame.midY),
                      lineHeight: Metrics.lineHeight, fontSize: Metrics.fontSize,
                      color: palette.text, in: &context)
        }
        for edge in layout.edges {
            guard let frame = edge.labelFrame, !edge.labelLines.isEmpty else { continue }
            let pill = Path(roundedRect: frame, cornerRadius: 4)
            context.fill(pill, with: .color(palette.labelFill))
            context.stroke(pill, with: .color(palette.edge.opacity(0.3)), lineWidth: 0.5)
            drawLines(edge.labelLines, center: CGPoint(x: frame.midX, y: frame.midY),
                      lineHeight: Metrics.labelLineHeight, fontSize: Metrics.labelFontSize,
                      color: palette.labelText, in: &context)
        }
    }

    private static func shapePath(_ shape: MermaidDiagram.Flowchart.Shape, in rect: CGRect) -> Path {
        switch shape {
        case .rectangle:
            return Path(roundedRect: rect, cornerRadius: 6)
        case .rounded:
            return Path(roundedRect: rect, cornerRadius: 12)
        case .stadium:
            return Path(roundedRect: rect, cornerRadius: rect.height / 2)
        case .circle:
            return Path(ellipseIn: rect)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        }
    }

    private static func drawEdge(_ edge: MermaidLayout.Edge, palette: MermaidPalette, in context: inout GraphicsContext) {
        guard edge.points.count >= 2, let first = edge.points.first, let last = edge.points.last else { return }

        var path = Path()
        path.move(to: first)
        var tangentStart = edge.points[edge.points.count - 2]
        if edge.points.count == 3 {
            // A curve that passes through the middle point.
            let m = edge.points[1]
            let control = CGPoint(x: 2 * m.x - (first.x + last.x) / 2, y: 2 * m.y - (first.y + last.y) / 2)
            path.addQuadCurve(to: last, control: control)
            tangentStart = control
        } else {
            for point in edge.points.dropFirst() { path.addLine(to: point) }
        }

        let width: CGFloat = edge.style == .thick ? 3 : 1.5
        let dash: [CGFloat] = edge.style == .dotted ? [5, 4] : []
        context.stroke(path, with: .color(palette.edge),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))

        guard edge.head != .bare else { return }
        let angle = atan2(last.y - tangentStart.y, last.x - tangentStart.x)
        let length: CGFloat = edge.style == .thick ? 13 : 10
        let spread: CGFloat = 0.45
        let left = CGPoint(x: last.x - length * cos(angle - spread), y: last.y - length * sin(angle - spread))
        let right = CGPoint(x: last.x - length * cos(angle + spread), y: last.y - length * sin(angle + spread))
        var head = Path()
        if edge.head == .filled {
            head.move(to: last)
            head.addLine(to: left)
            head.addLine(to: right)
            head.closeSubpath()
            context.fill(head, with: .color(palette.edge))
        } else {
            head.move(to: left)
            head.addLine(to: last)
            head.addLine(to: right)
            context.stroke(head, with: .color(palette.edge),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }

    /// Draws already-wrapped lines centred on `center`.
    private static func drawLines(_ lines: [String], center: CGPoint, lineHeight: CGFloat, fontSize: CGFloat,
                                  color: Color, in context: inout GraphicsContext) {
        let total = lineHeight * CGFloat(lines.count)
        for (i, line) in lines.enumerated() {
            var resolved = context.resolve(Text(verbatim: line).font(.system(size: fontSize)))
            resolved.shading = .color(color)
            let y = center.y - total / 2 + lineHeight * (CGFloat(i) + 0.5)
            context.draw(resolved, at: CGPoint(x: center.x, y: y), anchor: .center)
        }
    }
}

// MARK: - Copy

/// Renders a diagram to a PNG that pastes cleanly into other apps: opaque light
/// `Theme.field` background with the theme's light ink, 2x scale, regardless of
/// the app's appearance.
@MainActor
enum MermaidExport {
    static func pngData(for layout: MermaidLayout) -> Data? {
        guard layout.size.width > 0, layout.size.height > 0 else { return nil }
        let content = MermaidCanvas(layout: layout, palette: .adaptive)
            .frame(width: layout.size.width, height: layout.size.height)
            .background(Theme.field.color)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.isOpaque = true
        #if canImport(AppKit)
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }
}

@MainActor
enum MermaidPasteboard {
    /// Puts the picture and the Mermaid source on the pasteboard together, as one
    /// item, so a rich-text editor takes the image and a plain-text editor takes
    /// the source.
    static func copyDiagram(layout: MermaidLayout, source: String) {
        #if canImport(AppKit)
        let item = NSPasteboardItem()
        if let png = MermaidExport.pngData(for: layout) {
            item.setData(png, forType: .png)
        }
        item.setString(source, forType: .string)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        #endif
    }

    /// Just the Mermaid source, as text.
    static func copySource(_ source: String) {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(source, forType: .string)
        #endif
    }
}
