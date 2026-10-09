import Foundation

/// A small, pure-Swift reader for the Mermaid diagrams a local model puts in a
/// chat answer — flowcharts (`graph` / `flowchart`) and `sequenceDiagram`s — so
/// the app can draw them natively instead of showing the source. No Mermaid
/// engine, no web view, no JavaScript, no network.
///
/// ```
///   source ──parse──▶ MermaidDiagram ──layout──▶ MermaidLayout ──▶ SwiftUI
///   (text)            (nodes/edges)              (positions)        (Canvas)
/// ```
///
/// It is deliberately forgiving about the slips small models make (a stray `>`
/// after an edge label, a bare multi-word node name) and deliberately strict
/// about anything it can't draw: `parse` returns nil for an unsupported diagram
/// type, a malformed or half-streamed statement, or a diagram over the size
/// caps, and the caller falls back to showing the source.
enum MermaidDiagram: Equatable {
    case flowchart(Flowchart)
    case sequence(SequenceChart)

    /// Size caps: a diagram bigger than this is unreadable as a chat inline
    /// anyway, and the caps keep layout trivially cheap.
    static let maxNodes = 60
    static let maxEdges = 120
    static let maxSourceLength = 20_000

    /// How a connection is drawn.
    enum EdgeStyle: Equatable {
        case solid
        case dotted
        case thick
    }

    /// The end of a connection. `bare` is a plain line (`---`, `A->B`).
    enum ArrowHead: Equatable {
        case filled
        case open
        case bare
    }

    struct Flowchart: Equatable {
        enum Direction: Equatable {
            case leftToRight
            case rightToLeft
            case topToBottom
            case bottomToTop
        }

        enum Shape: Equatable {
            case rectangle
            case rounded
            case stadium
            case circle
            case diamond
        }

        struct Node: Equatable {
            var id: String
            var label: String
            var shape: Shape
        }

        struct Edge: Equatable {
            var from: String
            var to: String
            var label: String?
            var style: EdgeStyle
            var arrow: Bool
        }

        var direction: Direction
        var nodes: [Node]
        var edges: [Edge]
    }

    struct SequenceChart: Equatable {
        struct Participant: Equatable {
            var id: String
            var label: String
        }

        struct Message: Equatable {
            var from: String
            var to: String
            var text: String
            var style: EdgeStyle
            var head: ArrowHead
        }

        var participants: [Participant]
        var messages: [Message]
    }

    /// Parses Mermaid source; nil when it isn't a supported, complete diagram.
    static func parse(_ source: String) -> MermaidDiagram? {
        guard source.utf8.count <= maxSourceLength else { return nil }

        // Drop blank lines, `%%` comments/directives, and YAML front matter.
        var lines: [String] = []
        var inFrontMatter = false
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if lines.isEmpty && !inFrontMatter && line == "---" {
                inFrontMatter = true
                continue
            }
            if inFrontMatter {
                if line == "---" { inFrontMatter = false }
                continue
            }
            if line.hasPrefix("%%") { continue }
            lines.append(line)
        }
        guard let header = lines.first else { return nil }

        // The header may carry statements after a `;` ("graph LR; A-->B").
        let headerParts = header.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let words = headerParts[0].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let keyword = words.first?.lowercased() else { return nil }
        var statements: [String] = []
        if headerParts.count > 1 { statements.append(String(headerParts[1])) }
        statements.append(contentsOf: lines.dropFirst())

        switch keyword {
        case "graph", "flowchart":
            var direction = Flowchart.Direction.topToBottom
            if words.count > 1 {
                guard words.count == 2, let parsed = parseDirection(words[1]) else { return nil }
                direction = parsed
            }
            guard let chart = FlowchartParser.parse(statements: statements, direction: direction) else { return nil }
            return .flowchart(chart)
        case "sequencediagram":
            guard words.count == 1, let chart = SequenceParser.parse(statements: statements) else { return nil }
            return .sequence(chart)
        default:
            return nil
        }
    }

    private static func parseDirection(_ token: String) -> Flowchart.Direction? {
        switch token.uppercased() {
        case "LR": return .leftToRight
        case "RL": return .rightToLeft
        case "TD", "TB": return .topToBottom
        case "BT": return .bottomToTop
        default: return nil
        }
    }

    /// A short plain-language description for VoiceOver.
    var accessibilityDescription: String {
        switch self {
        case let .flowchart(chart):
            let names = chart.nodes.map { $0.label }
            return "Flowchart with \(Self.count(names.count, "item")): \(Self.list(names)). "
                + "\(Self.count(chart.edges.count, "connection"))."
        case let .sequence(chart):
            let names = chart.participants.map { $0.label }
            return "Sequence diagram between \(Self.list(names)), "
                + "with \(Self.count(chart.messages.count, "message"))."
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    private static func list(_ names: [String]) -> String {
        let shown = names.prefix(8).joined(separator: ", ")
        return names.count > 8 ? "\(shown), and \(names.count - 8) more" : shown
    }
}

// MARK: - Text helpers

/// Label clean-up and (approximate) text measurement shared by the parser and
/// the layout. Widths are estimates calibrated for a 13 pt system font — the
/// layout only needs boxes that comfortably hold the text, not exact metrics.
enum MermaidText {
    /// Strips quotes and simple HTML, turns `<br/>` into a space, decodes the
    /// handful of entities a model emits, and collapses whitespace.
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast())
        }
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</?[A-Za-z][^>]*>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let narrow = Set("iljtfIr.,;:'|!()[]-/\\".unicodeScalars)
    private static let wide = Set("mwMW@%".unicodeScalars)

    /// Estimated width in points of `text` at `fontSize`.
    static func width(_ text: String, fontSize: CGFloat = 13) -> CGFloat {
        var total: CGFloat = 0
        for scalar in text.unicodeScalars {
            if scalar == " " {
                total += 3.6
            } else if narrow.contains(scalar) {
                total += 4.4
            } else if wide.contains(scalar) {
                total += 11.5
            } else if scalar.value >= 65 && scalar.value <= 90 {
                total += 8.6
            } else if scalar.value >= 0x2E80 {
                total += 13
            } else {
                total += 7
            }
        }
        return total * fontSize / 13
    }

    /// Greedy word wrap to `maxWidth`, hard-splitting a single over-long word and
    /// ending an over-tall label with an ellipsis. Always returns at least one line.
    static func wrap(_ text: String, maxWidth: CGFloat, fontSize: CGFloat = 13, maxLines: Int = 4) -> [String] {
        var lines: [String] = []
        var current = ""
        for piece in text.split(separator: " ") {
            var word = String(piece)
            while width(word, fontSize: fontSize) > maxWidth && word.count > 1 {
                var prefix = ""
                for ch in word {
                    let next = prefix + String(ch)
                    if width(next, fontSize: fontSize) > maxWidth && !prefix.isEmpty { break }
                    prefix = next
                }
                if !current.isEmpty {
                    lines.append(current)
                    current = ""
                }
                lines.append(prefix)
                word = String(word.dropFirst(prefix.count))
            }
            if word.isEmpty { continue }
            let candidate = current.isEmpty ? word : current + " " + word
            if current.isEmpty || width(candidate, fontSize: fontSize) <= maxWidth {
                current = candidate
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        if lines.isEmpty { return [""] }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            lines[maxLines - 1] += "…"
        }
        return lines
    }
}

// MARK: - Flowchart parser

private enum FlowchartParser {
    /// First words of lines that style or group a flowchart but add no nodes of
    /// their own. They are skipped, never an error.
    static let ignoredKeywords: Set<String> = [
        "subgraph", "end", "classdef", "class", "style", "linkstyle",
        "click", "direction", "acctitle", "accdescr"
    ]

    struct NodeToken {
        var id: String
        var label: String?
        var shape: MermaidDiagram.Flowchart.Shape?
        var end: Int
    }

    struct EdgeToken {
        var length: Int
        var style: MermaidDiagram.EdgeStyle
        var arrow: Bool
        var label: String?
    }

    struct Builder {
        var nodes: [MermaidDiagram.Flowchart.Node] = []
        var edges: [MermaidDiagram.Flowchart.Edge] = []
        var indexByID: [String: Int] = [:]

        /// Adds a node, or updates an earlier one when this mention carries a
        /// label (so `A --> B` followed by `B[Done]` labels B). False at the cap.
        mutating func add(_ token: NodeToken) -> Bool {
            if let i = indexByID[token.id] {
                if let label = token.label {
                    nodes[i].label = label
                    nodes[i].shape = token.shape ?? .rectangle
                }
                return true
            }
            guard nodes.count < MermaidDiagram.maxNodes else { return false }
            indexByID[token.id] = nodes.count
            nodes.append(.init(id: token.id, label: token.label ?? token.id, shape: token.shape ?? .rectangle))
            return true
        }

        mutating func addEdge(from: String, to: String, op: EdgeToken, label: String?) -> Bool {
            guard edges.count < MermaidDiagram.maxEdges else { return false }
            edges.append(.init(from: from, to: to, label: label, style: op.style, arrow: op.arrow))
            return true
        }
    }

    static func parse(statements: [String], direction: MermaidDiagram.Flowchart.Direction) -> MermaidDiagram.Flowchart? {
        var builder = Builder()
        for line in statements {
            for part in splitStatements(line) {
                let statement = part.trimmingCharacters(in: .whitespaces)
                if statement.isEmpty { continue }
                let firstWord = statement
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first.map { $0.lowercased() } ?? ""
                if ignoredKeywords.contains(firstWord) { continue }
                if !parseStatement(statement, into: &builder) { return nil }
            }
        }
        guard !builder.nodes.isEmpty else { return nil }
        return MermaidDiagram.Flowchart(direction: direction, nodes: builder.nodes, edges: builder.edges)
    }

    /// Splits a line on `;`, but not inside quotes or brackets.
    static func splitStatements(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inQuote = false
        for ch in text {
            if ch == "\"" { inQuote.toggle() }
            if !inQuote {
                if ch == "[" || ch == "(" || ch == "{" {
                    depth += 1
                } else if ch == "]" || ch == ")" || ch == "}" {
                    depth = max(0, depth - 1)
                }
            }
            if ch == ";" && !inQuote && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    /// `node (edge node)*`, e.g. `A[Start] -->|yes| B --> C`.
    static func parseStatement(_ text: String, into builder: inout Builder) -> Bool {
        let c = Array(text)
        var pos = skipSpaces(c, 0)
        guard pos < c.count, let first = parseNode(c, pos), builder.add(first) else { return false }
        var previous = first.id
        pos = skipSpaces(c, first.end)

        while pos < c.count {
            guard let op = matchEdge(c, pos) else { return false }
            pos = skipSpaces(c, pos + op.length)
            var label = op.label
            if pos < c.count && c[pos] == "|" {
                var close = pos + 1
                while close < c.count && c[close] != "|" { close += 1 }
                guard close < c.count else { return false }
                let labelText = MermaidText.clean(String(c[(pos + 1)..<close]))
                if !labelText.isEmpty { label = labelText }
                pos = close + 1
                // Lenient: models often write `-->|label|> Target`.
                if pos < c.count && c[pos] == ">" { pos += 1 }
                pos = skipSpaces(c, pos)
            }
            guard pos < c.count, let next = parseNode(c, pos), builder.add(next) else { return false }
            guard builder.addEdge(from: previous, to: next.id, op: op, label: label) else { return false }
            previous = next.id
            pos = skipSpaces(c, next.end)
        }
        return true
    }

    static func skipSpaces(_ c: [Character], _ from: Int) -> Int {
        var i = from
        while i < c.count && (c[i] == " " || c[i] == "\t") { i += 1 }
        return i
    }

    // MARK: Nodes

    static func isIDCharacter(_ c: [Character], _ i: Int) -> Bool {
        let ch = c[i]
        if ch == "_" || ch.isLetter || ch.isNumber { return true }
        // A hyphen inside a name ("follow-up"), but not the start of `-->`.
        if ch == "-" && i + 1 < c.count {
            let next = c[i + 1]
            return next == "_" || next.isLetter || next.isNumber
        }
        return false
    }

    /// `id`, `id[text]`, `id(text)`, `id([text])`, `id((text))`, `id{text}`, or a
    /// bare name (possibly several words) used as both id and label.
    static func parseNode(_ c: [Character], _ start: Int) -> NodeToken? {
        guard start < c.count else { return nil }
        var j = start
        while j < c.count && isIDCharacter(c, j) { j += 1 }

        if j > start && j < c.count && (c[j] == "[" || c[j] == "(" || c[j] == "{") {
            guard let closeIndex = findClose(c, openIndex: j) else { return nil }
            let id = String(c[start..<j])
            let inner = String(c[(j + 1)..<closeIndex])
            let (shape, rawLabel) = shapeAndLabel(open: c[j], inner: inner)
            let label = MermaidText.clean(rawLabel)
            let end = skipClassSuffix(c, closeIndex + 1)
            return NodeToken(id: id, label: label.isEmpty ? id : label, shape: shape, end: end)
        }
        return parseBareNode(c, start)
    }

    static func parseBareNode(_ c: [Character], _ start: Int) -> NodeToken? {
        if c[start] == "\"" {
            var q = start + 1
            while q < c.count && c[q] != "\"" { q += 1 }
            guard q < c.count else { return nil }
            let text = MermaidText.clean(String(c[(start + 1)..<q]))
            guard !text.isEmpty else { return nil }
            return NodeToken(id: text, label: nil, shape: nil, end: q + 1)
        }
        var j = start
        while j < c.count {
            if (c[j] == "-" || c[j] == "=") && matchEdge(c, j) != nil { break }
            j += 1
        }
        var text = String(c[start..<j]).trimmingCharacters(in: .whitespaces)
        if let marker = text.range(of: ":::") {
            text = String(text[..<marker.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        // Brackets, quotes, `&` groups and the like in a bare name mean we
        // don't understand the statement; better to show the source.
        let forbidden = CharacterSet(charactersIn: "[](){}|\"<>&")
        guard !text.isEmpty, text.rangeOfCharacter(from: forbidden) == nil else { return nil }
        let name = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return NodeToken(id: name, label: nil, shape: nil, end: j)
    }

    /// Skips a `:::className` suffix after a node.
    static func skipClassSuffix(_ c: [Character], _ from: Int) -> Int {
        guard from + 2 < c.count, c[from] == ":", c[from + 1] == ":", c[from + 2] == ":" else { return from }
        var i = from + 3
        while i < c.count && (c[i].isLetter || c[i].isNumber || c[i] == "_" || c[i] == "-") { i += 1 }
        return i
    }

    /// Index of the bracket that closes the one at `openIndex`, honouring nesting
    /// and quoted text. Nil when it never closes (a half-streamed label).
    static func findClose(_ c: [Character], openIndex: Int) -> Int? {
        let open = c[openIndex]
        let close: Character = open == "[" ? "]" : (open == "(" ? ")" : "}")
        var depth = 0
        var inQuote = false
        var i = openIndex
        while i < c.count {
            let ch = c[i]
            if ch == "\"" {
                inQuote.toggle()
            } else if !inQuote {
                if ch == open {
                    depth += 1
                } else if ch == close {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i += 1
        }
        return nil
    }

    /// Reads `inner` of an opening bracket as a shape plus its label text.
    static func shapeAndLabel(open: Character, inner: String) -> (MermaidDiagram.Flowchart.Shape, String) {
        switch open {
        case "(":
            if unwrap(inner, "(", ")") != nil {
                var label = inner
                while let stripped = unwrap(label, "(", ")") { label = stripped }
                return (.circle, label)
            }
            if let stripped = unwrap(inner, "[", "]") { return (.stadium, stripped) }
            return (.rounded, inner)
        case "{":
            return (.diamond, unwrap(inner, "{", "}") ?? inner)
        default:
            // `[[subroutine]]`, `[(database)]`, `[/parallelogram/]` draw as plain boxes.
            let decorations: [(Character, Character)] = [
                ("[", "]"), ("(", ")"), ("/", "/"), ("\\", "\\"), ("/", "\\"), ("\\", "/")
            ]
            for (o, cl) in decorations {
                if let stripped = unwrap(inner, o, cl) { return (.rectangle, stripped) }
            }
            return (.rectangle, inner)
        }
    }

    /// `s` without one surrounding `open`/`close` pair, if it is wrapped by exactly one.
    static func unwrap(_ s: String, _ open: Character, _ close: Character) -> String? {
        let c = Array(s.trimmingCharacters(in: .whitespaces))
        guard c.count >= 2, c.first == open, c.last == close else { return nil }
        if open == "(" || open == "[" || open == "{" {
            guard findClose(c, openIndex: 0) == c.count - 1 else { return nil }
        }
        return String(c[1..<(c.count - 1)])
    }

    // MARK: Edges

    /// Recognises an edge operator at `i`: `-->`, `---`, `-.->`, `-.-`, `==>`,
    /// `===`, and the inline-label forms `-- text -->`, `-. text .->`, `== text ==>`.
    static func matchEdge(_ c: [Character], _ i: Int) -> EdgeToken? {
        let n = c.count
        guard i < n else { return nil }

        if c[i] == "-" {
            var j = i
            while j < n && c[j] == "-" { j += 1 }
            let dashes = j - i
            if dashes >= 2 {
                if j < n && c[j] == ">" {
                    return EdgeToken(length: j + 1 - i, style: .solid, arrow: true, label: nil)
                }
                if dashes >= 3 {
                    return EdgeToken(length: dashes, style: .solid, arrow: false, label: nil)
                }
                return labelledEdge(c, i, openLength: 2, close: "-", style: .solid)
            }
            // A single dash only starts an edge as `-.->`, `-.-` or `-. text .->`.
            guard j < n, c[j] == "." else { return nil }
            var k = j
            while k < n && c[k] == "." { k += 1 }
            if k < n && c[k] == "-" {
                if k + 1 < n && c[k + 1] == ">" {
                    return EdgeToken(length: k + 2 - i, style: .dotted, arrow: true, label: nil)
                }
                return EdgeToken(length: k + 1 - i, style: .dotted, arrow: false, label: nil)
            }
            return labelledEdge(c, i, openLength: k - i, close: ".", style: .dotted)
        }

        if c[i] == "=" {
            var j = i
            while j < n && c[j] == "=" { j += 1 }
            let equals = j - i
            guard equals >= 2 else { return nil }
            if j < n && c[j] == ">" {
                return EdgeToken(length: j + 1 - i, style: .thick, arrow: true, label: nil)
            }
            if equals >= 3 {
                return EdgeToken(length: equals, style: .thick, arrow: false, label: nil)
            }
            return labelledEdge(c, i, openLength: 2, close: "=", style: .thick)
        }
        return nil
    }

    /// The `-- text -->` family: an opener, whitespace, the label, then a closer.
    static func labelledEdge(_ c: [Character], _ i: Int, openLength: Int, close: Character,
                             style: MermaidDiagram.EdgeStyle) -> EdgeToken? {
        let n = c.count
        let textStart = i + openLength
        guard textStart < n, c[textStart] == " " || c[textStart] == "\t" else { return nil }
        var k = textStart
        while k + 1 < n {
            if close == "." {
                if c[k] == "." && c[k + 1] == "-" { break }
            } else if c[k] == close && c[k + 1] == close {
                break
            }
            k += 1
        }
        guard k + 1 < n else { return nil }
        let label = MermaidText.clean(String(c[textStart..<k]))
        var end = k
        if close == "." {
            end = k + 2
        } else {
            while end < n && c[end] == close { end += 1 }
        }
        if end < n && c[end] == ">" {
            return EdgeToken(length: end + 1 - i, style: style, arrow: true, label: label.isEmpty ? nil : label)
        }
        return EdgeToken(length: end - i, style: style, arrow: false, label: label.isEmpty ? nil : label)
    }
}

// MARK: - Sequence parser

private enum SequenceParser {
    struct Arrow {
        let token: String
        let style: MermaidDiagram.EdgeStyle
        let head: MermaidDiagram.ArrowHead
    }

    /// Longest first, so `-->>` wins over `-->` at the same position.
    static let operators: [Arrow] = [
        Arrow(token: "-->>", style: .dotted, head: .filled),
        Arrow(token: "->>", style: .solid, head: .filled),
        Arrow(token: "--)", style: .dotted, head: .open),
        Arrow(token: "-)", style: .solid, head: .open),
        Arrow(token: "-->", style: .dotted, head: .bare),
        Arrow(token: "->", style: .solid, head: .bare)
    ]

    /// Lines that structure or annotate a sequence diagram but add no arrows.
    static let ignoredKeywords: Set<String> = [
        "note", "loop", "alt", "else", "opt", "par", "and", "end", "rect", "critical",
        "break", "activate", "deactivate", "autonumber", "title", "box", "link", "links",
        "create", "destroy", "acctitle", "accdescr"
    ]

    static func parse(statements: [String]) -> MermaidDiagram.SequenceChart? {
        var participants: [MermaidDiagram.SequenceChart.Participant] = []
        var messages: [MermaidDiagram.SequenceChart.Message] = []

        // Declares (or relabels) a participant; false at the node cap.
        func declare(_ id: String, label: String?) -> Bool {
            if let i = participants.firstIndex(where: { $0.id == id }) {
                if let label = label { participants[i].label = label }
                return true
            }
            guard participants.count < MermaidDiagram.maxNodes else { return false }
            participants.append(.init(id: id, label: label ?? id))
            return true
        }

        for line in statements {
            for part in line.split(separator: ";", omittingEmptySubsequences: true) {
                let statement = part.trimmingCharacters(in: .whitespaces)
                if statement.isEmpty { continue }

                let lower = statement.lowercased()
                if lower.hasPrefix("participant ") || lower.hasPrefix("actor ") {
                    let keywordLength = lower.hasPrefix("actor ") ? 6 : 12
                    let rest = String(statement.dropFirst(keywordLength)).trimmingCharacters(in: .whitespaces)
                    var id = rest
                    var label: String?
                    if let r = rest.range(of: " as ", options: .caseInsensitive) {
                        id = String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                        let alias = MermaidText.clean(String(rest[r.upperBound...]))
                        if !alias.isEmpty { label = alias }
                    }
                    guard !id.isEmpty, declare(id, label: label) else { return nil }
                    continue
                }

                let firstWord = lower.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
                if ignoredKeywords.contains(firstWord) { continue }

                guard let message = parseMessage(statement),
                      messages.count < MermaidDiagram.maxEdges,
                      declare(message.from, label: nil),
                      declare(message.to, label: nil) else { return nil }
                messages.append(message)
            }
        }
        guard !participants.isEmpty else { return nil }
        return MermaidDiagram.SequenceChart(participants: participants, messages: messages)
    }

    /// `A->>B: text`, with optional `+`/`-` activation marks next to the target.
    static func parseMessage(_ statement: String) -> MermaidDiagram.SequenceChart.Message? {
        var left = statement
        var text = ""
        if let colon = statement.firstIndex(of: ":") {
            left = String(statement[..<colon])
            text = MermaidText.clean(String(statement[statement.index(after: colon)...]))
        }

        var best: (range: Range<String.Index>, op: Arrow)?
        for op in operators {
            guard let r = left.range(of: op.token) else { continue }
            if let current = best, r.lowerBound >= current.range.lowerBound { continue }
            best = (r, op)
        }
        guard let found = best else { return nil }

        let from = String(left[..<found.range.lowerBound]).trimmingCharacters(in: .whitespaces)
        var to = String(left[found.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        while let first = to.first, first == "+" || first == "-" { to.removeFirst() }
        to = to.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !to.isEmpty else { return nil }
        return .init(from: from, to: to, text: text, style: found.op.style, head: found.op.head)
    }
}
