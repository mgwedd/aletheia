import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Colours for drawing a diagram. `adaptive` uses semantic colours so it follows
/// light/dark mode on screen; `print` is fixed dark-on-white for the copied
/// picture, which has to read correctly pasted into Word, Mail, or Pages.
struct MermaidPalette {
    var nodeFill: Color
    var nodeStroke: Color
    var text: Color
    var edge: Color
    var labelFill: Color
    var labelText: Color
    var lifeline: Color

    static let adaptive = MermaidPalette(
        nodeFill: Color.accentColor.opacity(0.14),
        nodeStroke: Color.accentColor.opacity(0.75),
        text: Color.primary,
        edge: Color.secondary,
        labelFill: adaptiveBackground,
        labelText: Color.primary,
        lifeline: Color.secondary.opacity(0.5)
    )

    static let print = MermaidPalette(
        nodeFill: Color(red: 0.91, green: 0.94, blue: 0.99),
        nodeStroke: Color(red: 0.25, green: 0.40, blue: 0.70),
        text: Color(white: 0.1),
        edge: Color(white: 0.3),
        labelFill: Color.white,
        labelText: Color(white: 0.15),
        lifeline: Color(white: 0.6)
    )

    private static var adaptiveBackground: Color {
        #if canImport(AppKit)
        return Color(nsColor: .textBackgroundColor)
        #else
        return Color.white
        #endif
    }
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
                        .frame(maxWidth: natural.width)
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
            return Path(roundedRect: rect, cornerRadius: 4)
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

/// Renders a diagram to a PNG that pastes cleanly into other apps: opaque white
/// background, dark foreground, 2x scale, regardless of the app's appearance.
@MainActor
enum MermaidExport {
    static func pngData(for layout: MermaidLayout) -> Data? {
        guard layout.size.width > 0, layout.size.height > 0 else { return nil }
        let content = MermaidCanvas(layout: layout, palette: .print)
            .frame(width: layout.size.width, height: layout.size.height)
            .background(Color.white)
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
