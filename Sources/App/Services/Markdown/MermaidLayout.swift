import Foundation

/// A laid-out Mermaid diagram: every box, connector and label already has a
/// position, so the view only has to draw. Pure values (CoreGraphics geometry
/// via Foundation), no SwiftUI, so the layout is unit-testable.
///
/// Flowcharts use a layered layout:
///
/// ```
///   rank by longest path (back edges ignored, so cycles terminate)
///        │
///   order each layer by the barycenter of its neighbours
///        │
///   place layers along the flow axis, centre each across it
///        │
///   mirror for RL / BT, route edges, normalise to a margin
/// ```
///
/// Sequence diagrams are a row of participant boxes with a vertical lifeline
/// under each and one horizontal arrow per message.
struct MermaidLayout: Equatable {
    struct Node: Equatable {
        var id: String
        /// The label, already wrapped to fit inside `frame`.
        var lines: [String]
        var shape: MermaidDiagram.Flowchart.Shape
        var frame: CGRect
    }

    struct Edge: Equatable {
        /// Two points for a straight connector, three for a curve passing through
        /// the middle one, four or more for a polyline (a self-loop).
        var points: [CGPoint]
        var style: MermaidDiagram.EdgeStyle
        var head: MermaidDiagram.ArrowHead
        var labelLines: [String]
        var labelFrame: CGRect?
    }

    struct Lifeline: Equatable {
        var x: CGFloat
        var top: CGFloat
        var bottom: CGFloat
    }

    var size: CGSize
    var nodes: [Node]
    var edges: [Edge]
    var lifelines: [Lifeline]

    /// Drawing constants shared with the view so wrapped text matches the boxes.
    enum Metrics {
        static let fontSize: CGFloat = 13
        static let lineHeight: CGFloat = 17
        static let labelFontSize: CGFloat = 11
        static let labelLineHeight: CGFloat = 14
        static let margin: CGFloat = 16
    }
}

extension MermaidDiagram {
    /// Positions every element of the diagram.
    func layout() -> MermaidLayout {
        switch self {
        case let .flowchart(chart): return MermaidLayoutEngine.layout(chart)
        case let .sequence(chart): return MermaidLayoutEngine.layout(chart)
        }
    }

    /// Parses and lays out `source`, remembering the result so a streaming chat
    /// that re-renders on every token (or a hover) doesn't redo the work.
    static func cachedLayout(for source: String, diagram: MermaidDiagram) -> MermaidLayout {
        let key = source as NSString
        if let hit = MermaidLayoutCache.shared.object(forKey: key) { return hit.layout }
        let laid = diagram.layout()
        MermaidLayoutCache.shared.setObject(MermaidLayoutCache.Box(laid), forKey: key)
        return laid
    }
}

private enum MermaidLayoutCache {
    final class Box {
        let layout: MermaidLayout
        init(_ layout: MermaidLayout) { self.layout = layout }
    }

    static let shared: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64
        return cache
    }()
}

// MARK: - Engine

enum MermaidLayoutEngine {
    private typealias Metrics = MermaidLayout.Metrics

    // MARK: Flowchart

    static func layout(_ chart: MermaidDiagram.Flowchart) -> MermaidLayout {
        let count = chart.nodes.count
        guard count > 0 else {
            return MermaidLayout(size: .zero, nodes: [], edges: [], lifelines: [])
        }

        var indexByID: [String: Int] = [:]
        for (i, node) in chart.nodes.enumerated() { indexByID[node.id] = i }

        let sizing = chart.nodes.map { nodeSize(label: $0.label, shape: $0.shape) }
        let vertical = chart.direction == .topToBottom || chart.direction == .bottomToTop

        // 1. Rank. Edges that close a cycle are ignored, so any graph terminates.
        var outgoing = [[Int]](repeating: [], count: count)
        for edge in chart.edges {
            guard let a = indexByID[edge.from], let b = indexByID[edge.to], a != b else { continue }
            outgoing[a].append(b)
        }
        var state = [Int](repeating: 0, count: count) // 0 new, 1 on the stack, 2 done
        var forward = [[Int]](repeating: [], count: count)
        var postorder: [Int] = []
        func visit(_ v: Int) {
            state[v] = 1
            for w in outgoing[v] {
                if state[w] == 1 { continue } // back edge
                forward[v].append(w)
                if state[w] == 0 { visit(w) }
            }
            state[v] = 2
            postorder.append(v)
        }
        for v in 0..<count where state[v] == 0 { visit(v) }

        var layer = [Int](repeating: 0, count: count)
        for v in postorder.reversed() {
            for w in forward[v] { layer[w] = max(layer[w], layer[v] + 1) }
        }
        let layerCount = (layer.max() ?? 0) + 1

        // 2. Order within each layer by the barycenter of neighbours.
        var preds = [[Int]](repeating: [], count: count)
        for v in 0..<count { for w in forward[v] { preds[w].append(v) } }

        var order = [[Int]](repeating: [], count: layerCount)
        for v in 0..<count { order[layer[v]].append(v) }

        var pos = [CGFloat](repeating: 0, count: count)
        func refreshPositions() {
            for members in order {
                for (i, v) in members.enumerated() {
                    pos[v] = (CGFloat(i) + 0.5) / CGFloat(members.count)
                }
            }
        }
        refreshPositions()

        if layerCount > 1 {
            for sweep in 0..<4 {
                let down = sweep % 2 == 0
                let layers = down ? Array(1..<layerCount) : Array((0..<(layerCount - 1)).reversed())
                for l in layers {
                    var keys: [Int: CGFloat] = [:]
                    for v in order[l] {
                        let neighbours = down ? preds[v] : forward[v]
                        if neighbours.isEmpty {
                            keys[v] = pos[v]
                        } else {
                            var total: CGFloat = 0
                            for u in neighbours { total += pos[u] }
                            keys[v] = total / CGFloat(neighbours.count)
                        }
                    }
                    let ranked = order[l].enumerated().sorted { lhs, rhs in
                        let ka = keys[lhs.element] ?? 0
                        let kb = keys[rhs.element] ?? 0
                        if ka != kb { return ka < kb }
                        return lhs.offset < rhs.offset
                    }
                    order[l] = ranked.map { $0.element }
                    refreshPositions()
                }
            }
        }

        // 3. Place. "main" runs along the flow, "cross" across it.
        func mainSize(_ i: Int) -> CGFloat { vertical ? sizing[i].size.height : sizing[i].size.width }
        func crossSize(_ i: Int) -> CGFloat { vertical ? sizing[i].size.width : sizing[i].size.height }

        // Leave room between layers for the labels of the edges that leave them.
        var gap = [CGFloat](repeating: vertical ? 54 : 64, count: layerCount)
        for edge in chart.edges {
            guard let label = edge.label, let a = indexByID[edge.from], let b = indexByID[edge.to],
                  layer[a] < layer[b] else { continue }
            let box = labelSize(label).size
            let need = vertical ? box.height + 30 : box.width + 36
            gap[layer[a]] = max(gap[layer[a]], need)
        }

        var mainStart = [CGFloat](repeating: 0, count: layerCount)
        var thickness = [CGFloat](repeating: 0, count: layerCount)
        var cursor: CGFloat = 0
        for l in 0..<layerCount {
            mainStart[l] = cursor
            thickness[l] = order[l].map { mainSize($0) }.max() ?? 0
            cursor += thickness[l] + (l < layerCount - 1 ? gap[l] : 0)
        }
        let totalMain = cursor

        let crossGap: CGFloat = vertical ? 40 : 28
        var extents = [CGFloat](repeating: 0, count: layerCount)
        for l in 0..<layerCount {
            var sum: CGFloat = 0
            for v in order[l] { sum += crossSize(v) }
            extents[l] = sum + crossGap * CGFloat(max(0, order[l].count - 1))
        }
        let widest = extents.max() ?? 0

        var frames = [CGRect](repeating: .zero, count: count)
        for l in 0..<layerCount {
            var crossCursor = (widest - extents[l]) / 2
            for v in order[l] {
                let main = mainStart[l] + (thickness[l] - mainSize(v)) / 2
                let s = sizing[v].size
                var frame = vertical
                    ? CGRect(x: crossCursor, y: main, width: s.width, height: s.height)
                    : CGRect(x: main, y: crossCursor, width: s.width, height: s.height)
                if chart.direction == .bottomToTop {
                    frame.origin.y = totalMain - frame.maxY
                } else if chart.direction == .rightToLeft {
                    frame.origin.x = totalMain - frame.maxX
                }
                frames[v] = frame
                crossCursor += crossSize(v) + crossGap
            }
        }

        // 4. Route edges.
        let perpendicular = vertical ? CGPoint(x: 1, y: 0) : CGPoint(x: 0, y: 1)
        var seenPairs: [Int: Int] = [:]
        var edges: [MermaidLayout.Edge] = []
        for edge in chart.edges {
            guard let a = indexByID[edge.from], let b = indexByID[edge.to] else { continue }
            let label = edge.label.map { labelSize($0) }
            let head: MermaidDiagram.ArrowHead = edge.arrow ? .filled : .bare

            if a == b {
                let f = frames[a]
                let y = f.midY
                let points = [
                    CGPoint(x: f.maxX, y: y - 8), CGPoint(x: f.maxX + 24, y: y - 8),
                    CGPoint(x: f.maxX + 24, y: y + 8), CGPoint(x: f.maxX, y: y + 8)
                ]
                var labelFrame: CGRect?
                if let label = label {
                    labelFrame = CGRect(x: f.maxX + 28, y: y - label.size.height / 2,
                                        width: label.size.width, height: label.size.height)
                }
                edges.append(.init(points: points, style: edge.style, head: head,
                                   labelLines: label?.lines ?? [], labelFrame: labelFrame))
                continue
            }

            let ca = center(frames[a])
            let cb = center(frames[b])
            let isBack = layer[b] <= layer[a]
            let key = a * count + b
            let seen = seenPairs[key] ?? 0
            seenPairs[key] = seen + 1
            var bend: CGFloat = 0
            if isBack {
                bend = 40 + 16 * CGFloat(seen)
            } else if seen > 0 {
                let sign: CGFloat = seen % 2 == 1 ? 1 : -1
                bend = sign * 22 * CGFloat((seen + 1) / 2)
            }

            let points: [CGPoint]
            let mid: CGPoint
            if bend == 0 {
                let s = boundary(frames[a], chart.nodes[a].shape, toward: cb)
                let e = boundary(frames[b], chart.nodes[b].shape, toward: ca)
                points = [s, e]
                mid = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
            } else {
                let m = CGPoint(x: (ca.x + cb.x) / 2 + perpendicular.x * bend,
                                y: (ca.y + cb.y) / 2 + perpendicular.y * bend)
                let s = boundary(frames[a], chart.nodes[a].shape, toward: m)
                let e = boundary(frames[b], chart.nodes[b].shape, toward: m)
                points = [s, m, e]
                mid = m
            }
            var labelFrame: CGRect?
            if let label = label {
                labelFrame = CGRect(x: mid.x - label.size.width / 2, y: mid.y - label.size.height / 2,
                                    width: label.size.width, height: label.size.height)
            }
            edges.append(.init(points: points, style: edge.style, head: head,
                               labelLines: label?.lines ?? [], labelFrame: labelFrame))
        }

        var nodes: [MermaidLayout.Node] = []
        for (i, node) in chart.nodes.enumerated() {
            nodes.append(.init(id: node.id, lines: sizing[i].lines, shape: node.shape, frame: frames[i]))
        }
        return normalized(nodes: nodes, edges: edges, lifelines: [])
    }

    // MARK: Sequence

    static func layout(_ chart: MermaidDiagram.SequenceChart) -> MermaidLayout {
        let count = chart.participants.count
        guard count > 0 else {
            return MermaidLayout(size: .zero, nodes: [], edges: [], lifelines: [])
        }
        var indexByID: [String: Int] = [:]
        for (i, p) in chart.participants.enumerated() { indexByID[p.id] = i }

        // Header boxes.
        var headerLines: [[String]] = []
        var widths: [CGFloat] = []
        var headerHeight: CGFloat = 0
        for p in chart.participants {
            let lines = MermaidText.wrap(p.label, maxWidth: 140)
            let textWidth = lines.map { MermaidText.width($0) }.max() ?? 0
            headerLines.append(lines)
            widths.append(max(96, textWidth + 28))
            headerHeight = max(headerHeight, CGFloat(lines.count) * Metrics.lineHeight + 18)
        }
        headerHeight = max(headerHeight, 38)

        // Space between lifelines, widened so each message's label fits.
        var gaps: [CGFloat] = []
        if count > 1 {
            for i in 0..<(count - 1) { gaps.append((widths[i] + widths[i + 1]) / 2 + 28) }
        }
        struct Row {
            var from: Int
            var to: Int
            var message: MermaidDiagram.SequenceChart.Message
            var label: (lines: [String], size: CGSize)?
        }
        var rows: [Row] = []
        for message in chart.messages {
            guard let a = indexByID[message.from], let b = indexByID[message.to] else { continue }
            let label: (lines: [String], size: CGSize)? = message.text.isEmpty ? nil : labelSize(message.text, maxWidth: 200)
            rows.append(Row(from: a, to: b, message: message, label: label))
        }
        let bySpan = rows.indices.sorted { abs(rows[$0].to - rows[$0].from) < abs(rows[$1].to - rows[$1].from) }
        for r in bySpan {
            let lo = min(rows[r].from, rows[r].to)
            let hi = max(rows[r].from, rows[r].to)
            guard lo != hi, let label = rows[r].label else { continue }
            var distance: CGFloat = 0
            for i in lo..<hi { distance += gaps[i] }
            let required = label.size.width + 36
            if distance < required {
                let extra = (required - distance) / CGFloat(hi - lo)
                for i in lo..<hi { gaps[i] += extra }
            }
        }

        var centers: [CGFloat] = [widths[0] / 2]
        if count > 1 {
            for i in 1..<count { centers.append(centers[i - 1] + gaps[i - 1]) }
        }

        var nodes: [MermaidLayout.Node] = []
        for (i, p) in chart.participants.enumerated() {
            let frame = CGRect(x: centers[i] - widths[i] / 2, y: 0, width: widths[i], height: headerHeight)
            nodes.append(.init(id: p.id, lines: headerLines[i], shape: .rounded, frame: frame))
        }

        // One row per message, top to bottom.
        var edges: [MermaidLayout.Edge] = []
        var y = headerHeight + 18
        for row in rows {
            let labelHeight = row.label?.size.height ?? 0
            let lineY = y + max(20, labelHeight + 10)
            let x1 = centers[row.from]
            let x2 = centers[row.to]
            let head = row.message.head
            if row.from == row.to {
                let points = [
                    CGPoint(x: x1, y: lineY), CGPoint(x: x1 + 32, y: lineY),
                    CGPoint(x: x1 + 32, y: lineY + 16), CGPoint(x: x1, y: lineY + 16)
                ]
                var labelFrame: CGRect?
                if let label = row.label {
                    labelFrame = CGRect(x: x1 + 38, y: lineY + 8 - label.size.height / 2,
                                        width: label.size.width, height: label.size.height)
                }
                edges.append(.init(points: points, style: row.message.style, head: head,
                                   labelLines: row.label?.lines ?? [], labelFrame: labelFrame))
                y = lineY + 16 + 18
            } else {
                var labelFrame: CGRect?
                if let label = row.label {
                    labelFrame = CGRect(x: (x1 + x2) / 2 - label.size.width / 2,
                                        y: lineY - 4 - label.size.height,
                                        width: label.size.width, height: label.size.height)
                }
                edges.append(.init(points: [CGPoint(x: x1, y: lineY), CGPoint(x: x2, y: lineY)],
                                   style: row.message.style, head: head,
                                   labelLines: row.label?.lines ?? [], labelFrame: labelFrame))
                y = lineY + 18
            }
        }

        let lifelines = centers.map { MermaidLayout.Lifeline(x: $0, top: headerHeight, bottom: y + 4) }
        return normalized(nodes: nodes, edges: edges, lifelines: lifelines)
    }

    // MARK: Geometry helpers

    /// Wrapped lines and the padded box for an edge or message label.
    static func labelSize(_ text: String, maxWidth: CGFloat = 150) -> (lines: [String], size: CGSize) {
        let lines = MermaidText.wrap(text, maxWidth: maxWidth, fontSize: Metrics.labelFontSize, maxLines: 3)
        let textWidth = lines.map { MermaidText.width($0, fontSize: Metrics.labelFontSize) }.max() ?? 0
        let size = CGSize(width: textWidth + 12, height: CGFloat(lines.count) * Metrics.labelLineHeight + 6)
        return (lines, size)
    }

    /// Wrapped lines and a box big enough to hold them inside the given shape.
    static func nodeSize(label: String, shape: MermaidDiagram.Flowchart.Shape) -> (lines: [String], size: CGSize) {
        let maxText: CGFloat
        switch shape {
        case .diamond: maxText = 120
        case .circle: maxText = 110
        default: maxText = 190
        }
        let lines = MermaidText.wrap(label, maxWidth: maxText)
        let textWidth = lines.map { MermaidText.width($0) }.max() ?? 0
        let textHeight = CGFloat(lines.count) * Metrics.lineHeight
        switch shape {
        case .rectangle, .rounded:
            return (lines, CGSize(width: max(64, textWidth + 28), height: max(38, textHeight + 20)))
        case .stadium:
            return (lines, CGSize(width: max(72, textWidth + 40), height: max(38, textHeight + 20)))
        case .circle:
            let d = max(52, (textWidth * textWidth + textHeight * textHeight).squareRoot() + 18)
            return (lines, CGSize(width: d, height: d))
        case .diamond:
            return (lines, CGSize(width: max(90, (textWidth + 20) * 2), height: max(52, (textHeight + 10) * 2)))
        }
    }

    private static func center(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Where a line from `frame`'s centre toward `target` leaves the shape.
    static func boundary(_ frame: CGRect, _ shape: MermaidDiagram.Flowchart.Shape, toward target: CGPoint) -> CGPoint {
        let c = center(frame)
        let dx = target.x - c.x
        let dy = target.y - c.y
        guard dx != 0 || dy != 0 else { return c }
        let halfW = frame.width / 2
        let halfH = frame.height / 2
        let t: CGFloat
        switch shape {
        case .circle:
            t = halfW / (dx * dx + dy * dy).squareRoot()
        case .diamond:
            t = 1 / (abs(dx) / halfW + abs(dy) / halfH)
        default:
            let tx = dx == 0 ? CGFloat.greatestFiniteMagnitude : halfW / abs(dx)
            let ty = dy == 0 ? CGFloat.greatestFiniteMagnitude : halfH / abs(dy)
            t = min(tx, ty)
        }
        return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
    }

    /// Shifts everything so the content sits `margin` from the top-left, and
    /// sizes the canvas to include every node, connector, label and lifeline.
    private static func normalized(nodes: [MermaidLayout.Node], edges: [MermaidLayout.Edge],
                                   lifelines: [MermaidLayout.Lifeline]) -> MermaidLayout {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        func includePoint(_ x: CGFloat, _ y: CGFloat) {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
        func includeRect(_ rect: CGRect) {
            includePoint(rect.minX, rect.minY)
            includePoint(rect.maxX, rect.maxY)
        }
        for node in nodes { includeRect(node.frame) }
        for edge in edges {
            for p in edge.points { includePoint(p.x, p.y) }
            if let label = edge.labelFrame { includeRect(label) }
        }
        for line in lifelines {
            includePoint(line.x, line.top)
            includePoint(line.x, line.bottom)
        }
        guard minX <= maxX, minY <= maxY else {
            return MermaidLayout(size: .zero, nodes: nodes, edges: edges, lifelines: lifelines)
        }

        let dx = Metrics.margin - minX
        let dy = Metrics.margin - minY
        func shiftPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        func shiftRect(_ r: CGRect) -> CGRect { r.offsetBy(dx: dx, dy: dy) }

        var outNodes = nodes
        for i in outNodes.indices { outNodes[i].frame = shiftRect(outNodes[i].frame) }
        var outEdges = edges
        for i in outEdges.indices {
            outEdges[i].points = outEdges[i].points.map { shiftPoint($0) }
            if let label = outEdges[i].labelFrame { outEdges[i].labelFrame = shiftRect(label) }
        }
        var outLines = lifelines
        for i in outLines.indices {
            outLines[i].x += dx
            outLines[i].top += dy
            outLines[i].bottom += dy
        }
        let size = CGSize(width: maxX - minX + 2 * Metrics.margin, height: maxY - minY + 2 * Metrics.margin)
        return MermaidLayout(size: size, nodes: outNodes, edges: outEdges, lifelines: outLines)
    }
}
