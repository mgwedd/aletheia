import XCTest
@testable import Aletheia

final class MermaidDiagramTests: XCTestCase {
    // MARK: Helpers

    private func flowchart(_ source: String, file: StaticString = #filePath, line: UInt = #line) -> MermaidDiagram.Flowchart? {
        guard case let .flowchart(chart)? = MermaidDiagram.parse(source) else {
            XCTFail("expected a flowchart", file: file, line: line)
            return nil
        }
        return chart
    }

    private func sequence(_ source: String, file: StaticString = #filePath, line: UInt = #line) -> MermaidDiagram.SequenceChart? {
        guard case let .sequence(chart)? = MermaidDiagram.parse(source) else {
            XCTFail("expected a sequence diagram", file: file, line: line)
            return nil
        }
        return chart
    }

    private func layoutOf(_ source: String, file: StaticString = #filePath, line: UInt = #line) -> MermaidLayout? {
        guard let diagram = MermaidDiagram.parse(source) else {
            XCTFail("expected the diagram to parse", file: file, line: line)
            return nil
        }
        return diagram.layout()
    }

    private func frame(_ layout: MermaidLayout, _ id: String) -> CGRect {
        layout.nodes.first(where: { $0.id == id })?.frame ?? .zero
    }

    // MARK: Flowchart parsing

    func testSimpleLeftToRight() {
        guard let chart = flowchart("graph LR; A-->B") else { return }
        XCTAssertEqual(chart.direction, .leftToRight)
        XCTAssertEqual(chart.nodes.map { $0.id }, ["A", "B"])
        XCTAssertEqual(chart.edges.count, 1)
        XCTAssertEqual(chart.edges[0].from, "A")
        XCTAssertEqual(chart.edges[0].to, "B")
        XCTAssertEqual(chart.edges[0].style, .solid)
        XCTAssertTrue(chart.edges[0].arrow)
        XCTAssertNil(chart.edges[0].label)
    }

    func testDirections() {
        XCTAssertEqual(flowchart("graph TD\nA-->B")?.direction, .topToBottom)
        XCTAssertEqual(flowchart("graph TB\nA-->B")?.direction, .topToBottom)
        XCTAssertEqual(flowchart("flowchart BT\nA-->B")?.direction, .bottomToTop)
        XCTAssertEqual(flowchart("flowchart RL;\nA-->B")?.direction, .rightToLeft)
        XCTAssertEqual(flowchart("graph\nA-->B")?.direction, .topToBottom)
        XCTAssertNil(MermaidDiagram.parse("graph XY\nA-->B"))
    }

    func testNodeShapes() {
        let source = """
        flowchart TD
          a[Rect] --> b(Round)
          b --> c([Stadium])
          c --> d((Circle))
          d --> e{Decision}
        """
        guard let chart = flowchart(source) else { return }
        let shapes = chart.nodes.map { $0.shape }
        XCTAssertEqual(shapes, [.rectangle, .rounded, .stadium, .circle, .diamond])
        XCTAssertEqual(chart.nodes.map { $0.label }, ["Rect", "Round", "Stadium", "Circle", "Decision"])
    }

    func testBareNodeReusesEarlierLabel() {
        guard let chart = flowchart("graph TD\n  A[Start] --> B\n  B --> A") else { return }
        XCTAssertEqual(chart.nodes.count, 2)
        XCTAssertEqual(chart.nodes[0].label, "Start")
        XCTAssertEqual(chart.nodes[1].label, "B")
    }

    func testLaterLabelRelabelsAnEarlierBareNode() {
        guard let chart = flowchart("graph TD\n  A --> B\n  B[Done]") else { return }
        XCTAssertEqual(chart.nodes[1].label, "Done")
    }

    func testQuotedLabelsAndLineBreaks() {
        guard let chart = flowchart("graph TD\n  A[\"Hello<br/>world\"] --> B[\"Care (weekly)\"]") else { return }
        XCTAssertEqual(chart.nodes[0].label, "Hello world")
        XCTAssertEqual(chart.nodes[1].label, "Care (weekly)")
    }

    func testEdgeLabelsInBothSyntaxes() {
        guard let chart = flowchart("graph LR\n  A -->|yes| B\n  B -- no --> C") else { return }
        XCTAssertEqual(chart.edges.map { $0.label }, ["yes", "no"])
        XCTAssertEqual(chart.edges.map { $0.arrow }, [true, true])
    }

    func testEdgeStyles() {
        let source = "graph LR\n  A -.-> B\n  B ==> C\n  C --- D\n  D -. maybe .-> E\n  E == strong ==> F"
        guard let chart = flowchart(source) else { return }
        XCTAssertEqual(chart.edges.map { $0.style }, [.dotted, .thick, .solid, .dotted, .thick])
        XCTAssertEqual(chart.edges.map { $0.arrow }, [true, true, false, true, true])
        XCTAssertEqual(chart.edges[3].label, "maybe")
        XCTAssertEqual(chart.edges[4].label, "strong")
    }

    func testChainsAndMultipleStatementsPerLine() {
        guard let chain = flowchart("graph LR\n  A --> B --> C") else { return }
        XCTAssertEqual(chain.nodes.count, 3)
        XCTAssertEqual(chain.edges.map { "\($0.from)>\($0.to)" }, ["A>B", "B>C"])

        guard let multi = flowchart("graph TD; A-->B; B-->C; C-->A;") else { return }
        XCTAssertEqual(multi.nodes.count, 3)
        XCTAssertEqual(multi.edges.count, 3)
    }

    func testSemicolonInsideALabelDoesNotSplit() {
        guard let chart = flowchart("graph TD\n  A[\"one; two\"] --> B") else { return }
        XCTAssertEqual(chart.nodes[0].label, "one; two")
    }

    func testModelFailureExampleParses() {
        let source = """
        graph LR;
            Participant[Therapist]-->|Testing transcription features|> Session
            Session-->|No actual therapy conversation|> Patient issues
            Session-->|Silence from call audio|> Call audio
        """
        guard let chart = flowchart(source) else { return }
        XCTAssertEqual(chart.nodes.map { $0.id }, ["Participant", "Session", "Patient issues", "Call audio"])
        XCTAssertEqual(chart.nodes.map { $0.label }, ["Therapist", "Session", "Patient issues", "Call audio"])
        XCTAssertEqual(chart.edges.count, 3)
        XCTAssertEqual(chart.edges.map { $0.label ?? "" }, [
            "Testing transcription features",
            "No actual therapy conversation",
            "Silence from call audio"
        ])
        XCTAssertEqual(chart.edges.map { $0.to }, ["Session", "Patient issues", "Call audio"])
    }

    func testStrayGreaterThanAfterLabelIsAccepted() {
        guard let chart = flowchart("graph LR\n  A-->|go|> B") else { return }
        XCTAssertEqual(chart.edges.first?.label, "go")
        XCTAssertEqual(chart.nodes.map { $0.id }, ["A", "B"])
    }

    func testBareMultiWordTargetIsBothIdAndLabel() {
        guard let chart = flowchart("graph TD\n  Start --> Patient issues --> Next step") else { return }
        XCTAssertEqual(chart.nodes.map { $0.id }, ["Start", "Patient issues", "Next step"])
        XCTAssertEqual(chart.nodes.map { $0.label }, ["Start", "Patient issues", "Next step"])
    }

    func testStyleAndGroupingLinesAreIgnored() {
        let source = """
        graph TD
          %% a comment
          subgraph One
            A --> B
          end
          classDef red fill:#f00
          class A red
          style B fill:#bbf,stroke:#333
          linkStyle 0 stroke:#ff3
          A --> C
        """
        guard let chart = flowchart(source) else { return }
        XCTAssertEqual(chart.nodes.map { $0.id }, ["A", "B", "C"])
        XCTAssertEqual(chart.edges.count, 2)
    }

    func testUnsupportedOrInvalidSourceIsNil() {
        XCTAssertNil(MermaidDiagram.parse(""))
        XCTAssertNil(MermaidDiagram.parse("pie title Pets\n  \"Dogs\" : 386"))
        XCTAssertNil(MermaidDiagram.parse("gantt\n  title Plan"))
        XCTAssertNil(MermaidDiagram.parse("classDiagram\n  A <|-- B"))
        XCTAssertNil(MermaidDiagram.parse("graph LR"))
        XCTAssertNil(MermaidDiagram.parse("just some text"))
    }

    func testHalfStreamedStatementsAreNil() {
        XCTAssertNil(MermaidDiagram.parse("graph TD\n  A -->"))
        XCTAssertNil(MermaidDiagram.parse("graph TD\n  A --> B[Open"))
        XCTAssertNil(MermaidDiagram.parse("graph TD\n  A -->|label"))
    }

    func testNodeCap() {
        let atCap = (0..<MermaidDiagram.maxNodes).map { "N\($0)" }.joined(separator: " --> ")
        XCTAssertNotNil(MermaidDiagram.parse("graph LR\n" + atCap))
        let overCap = (0...MermaidDiagram.maxNodes).map { "N\($0)" }.joined(separator: " --> ")
        XCTAssertNil(MermaidDiagram.parse("graph LR\n" + overCap))
    }

    func testEdgeCap() {
        let atCap = Array(repeating: "A --> B", count: MermaidDiagram.maxEdges).joined(separator: "\n")
        XCTAssertNotNil(MermaidDiagram.parse("graph LR\n" + atCap))
        let overCap = Array(repeating: "A --> B", count: MermaidDiagram.maxEdges + 1).joined(separator: "\n")
        XCTAssertNil(MermaidDiagram.parse("graph LR\n" + overCap))
    }

    func testAccessibilityDescriptionListsLabels() {
        guard let diagram = MermaidDiagram.parse("graph LR\n  A[Therapist] --> B[Client]") else {
            return XCTFail("expected a diagram")
        }
        let text = diagram.accessibilityDescription
        XCTAssertTrue(text.contains("Therapist"))
        XCTAssertTrue(text.contains("Client"))
        XCTAssertTrue(text.contains("1 connection"))
    }

    // MARK: Flowchart layout

    func testLeftToRightPlacesSuccessorToTheRight() {
        guard let layout = layoutOf("graph LR\n  A --> B") else { return }
        let a = frame(layout, "A")
        let b = frame(layout, "B")
        XCTAssertGreaterThan(b.minX, a.maxX)
        XCTAssertEqual(a.midY, b.midY, accuracy: 0.5)
    }

    func testTopDownPlacesSuccessorBelow() {
        guard let layout = layoutOf("graph TD\n  A --> B") else { return }
        let a = frame(layout, "A")
        let b = frame(layout, "B")
        XCTAssertGreaterThan(b.minY, a.maxY)
        XCTAssertEqual(a.midX, b.midX, accuracy: 0.5)
    }

    func testReversedDirectionsMirror() {
        if let rl = layoutOf("graph RL\n  A --> B") {
            XCTAssertLessThan(frame(rl, "B").maxX, frame(rl, "A").minX)
        }
        if let bt = layoutOf("graph BT\n  A --> B") {
            XCTAssertLessThan(frame(bt, "B").maxY, frame(bt, "A").minY)
        }
    }

    func testCycleLaysOutWithoutHanging() {
        guard let layout = layoutOf("graph TD\n  A --> B --> A") else { return }
        XCTAssertEqual(layout.nodes.count, 2)
        XCTAssertEqual(layout.edges.count, 2)
        XCTAssertLessThan(frame(layout, "A").minY, frame(layout, "B").minY)
        // The edge that closes the loop is bent so it doesn't sit on the other one.
        XCTAssertEqual(layout.edges[1].points.count, 3)
    }

    func testSelfLoopAndLongerCycleLayOut() {
        XCTAssertNotNil(layoutOf("graph LR\n  A --> A"))
        guard let layout = layoutOf("graph LR\n  A --> B\n  B --> C\n  C --> A\n  C --> C") else { return }
        XCTAssertEqual(layout.nodes.count, 3)
        XCTAssertGreaterThan(layout.size.width, 0)
        XCTAssertGreaterThan(layout.size.height, 0)
    }

    func testBranchesDoNotOverlapAndStayInsideTheCanvas() {
        guard let layout = layoutOf("graph TD\n  A --> B\n  A --> C\n  B --> D\n  C --> D") else { return }
        XCTAssertEqual(layout.nodes.count, 4)
        for (i, first) in layout.nodes.enumerated() {
            XCTAssertGreaterThanOrEqual(first.frame.minX, 0)
            XCTAssertGreaterThanOrEqual(first.frame.minY, 0)
            XCTAssertLessThanOrEqual(first.frame.maxX, layout.size.width)
            XCTAssertLessThanOrEqual(first.frame.maxY, layout.size.height)
            for second in layout.nodes.dropFirst(i + 1) {
                XCTAssertFalse(first.frame.intersects(second.frame), "\(first.id) overlaps \(second.id)")
            }
        }
        XCTAssertGreaterThan(frame(layout, "D").minY, frame(layout, "B").maxY)
    }

    func testLongLabelsWrapInsideTheirNode() {
        let label = "A very long label that certainly needs to wrap onto several lines"
        guard let layout = layoutOf("graph TD\n  A[\(label)] --> B"),
              let node = layout.nodes.first(where: { $0.id == "A" }) else { return }
        XCTAssertGreaterThan(node.lines.count, 1)
        XCTAssertEqual(node.lines.joined(separator: " "), label)
        XCTAssertGreaterThan(node.frame.height, frame(layout, "B").height)
    }

    func testEdgeLabelsGetAFrame() {
        guard let layout = layoutOf("graph LR\n  A -->|yes| B") else { return }
        XCTAssertNotNil(layout.edges[0].labelFrame)
        XCTAssertEqual(layout.edges[0].labelLines, ["yes"])
    }

    // MARK: Sequence diagrams

    func testSequenceParticipantsAndMessages() {
        let source = """
        sequenceDiagram
            participant T as Therapist
            actor C as Client
            T->>C: How was your week?
            C-->>T: Better
            Note over T,C: ignored
            loop Weekly
              T-)C: ping
            end
            T->C: plain
            C-->T: dotted plain
            activate T
        """
        guard let chart = sequence(source) else { return }
        XCTAssertEqual(chart.participants.map { $0.id }, ["T", "C"])
        XCTAssertEqual(chart.participants.map { $0.label }, ["Therapist", "Client"])
        XCTAssertEqual(chart.messages.count, 5)
        XCTAssertEqual(chart.messages[0].text, "How was your week?")
        XCTAssertEqual(chart.messages[0].head, .filled)
        XCTAssertEqual(chart.messages[0].style, .solid)
        XCTAssertEqual(chart.messages[1].from, "C")
        XCTAssertEqual(chart.messages[1].style, .dotted)
        XCTAssertEqual(chart.messages[1].head, .filled)
        XCTAssertEqual(chart.messages[2].head, .open)
        XCTAssertEqual(chart.messages[3].head, .bare)
        XCTAssertEqual(chart.messages[4].style, .dotted)
        XCTAssertEqual(chart.messages[4].head, .bare)
    }

    func testSequenceImplicitParticipantsKeepFirstAppearanceOrder() {
        guard let chart = sequence("sequenceDiagram\n  B->>A: hi\n  A->>C: there") else { return }
        XCTAssertEqual(chart.participants.map { $0.id }, ["B", "A", "C"])
    }

    func testSequenceWithoutParticipantsIsNil() {
        XCTAssertNil(MermaidDiagram.parse("sequenceDiagram"))
        XCTAssertNil(MermaidDiagram.parse("sequenceDiagram\n  this is not a message"))
    }

    func testSequenceLayout() {
        let source = "sequenceDiagram\n  A->>B: hi\n  B->>C: a longer message here\n  C-->>A: done"
        guard let layout = layoutOf(source) else { return }
        XCTAssertEqual(layout.nodes.count, 3)
        XCTAssertEqual(layout.lifelines.count, 3)
        XCTAssertEqual(layout.edges.count, 3)
        XCTAssertLessThan(frame(layout, "A").minX, frame(layout, "B").minX)
        XCTAssertLessThan(frame(layout, "B").minX, frame(layout, "C").minX)
        let ys = layout.edges.map { $0.points[0].y }
        XCTAssertEqual(ys, ys.sorted())
        for edge in layout.edges {
            XCTAssertEqual(edge.points[0].y, edge.points[1].y, accuracy: 0.001)
            XCTAssertNotNil(edge.labelFrame)
        }
        // The first arrow runs from A's lifeline to B's.
        XCTAssertEqual(layout.edges[0].points[0].x, layout.lifelines[0].x, accuracy: 0.001)
        XCTAssertEqual(layout.edges[0].points[1].x, layout.lifelines[1].x, accuracy: 0.001)
    }

    // MARK: Text helpers

    func testCleanDecodesEntitiesAndStripsTags() {
        XCTAssertEqual(MermaidText.clean(" \"a &amp; b\" "), "a & b")
        XCTAssertEqual(MermaidText.clean("one<br>two<BR />three"), "one two three")
        XCTAssertEqual(MermaidText.clean("<b>bold</b>  text"), "bold text")
    }

    func testWrapSplitsLongWordsAndCapsLines() {
        let lines = MermaidText.wrap(String(repeating: "x", count: 200), maxWidth: 100)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertLessThanOrEqual(lines.count, 4)
        XCTAssertEqual(MermaidText.wrap("", maxWidth: 100), [""])
    }
}
