import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

/// A collapsed sidebar must never be a dead end: the title-bar toggle is the one
/// toolbar item (nothing can push it into the » overflow), and View > Show/Hide
/// Sidebar exists.
@MainActor
final class SidebarVisibilityTests: XCTestCase {
    private struct NoopSpotlightIndexer: SpotlightIndexing {
        func replaceIndex(with entries: [SpotlightEntry]) {}
        func clear() {}
    }

    private final class Visibility: ObservableObject {
        @Published var shown = true
        @Published var width = Double(SidebarLayout.idealWidth)
    }

    private struct Host: View {
        let appModel: AppModel
        let settings: AppSettings
        @ObservedObject var state: Visibility
        @StateObject private var search = GlobalSearchModel()
        @FocusState private var focused: Bool
        @FocusState private var homeFocused: Bool
        @State private var selected: Patient?

        var body: some View {
            LeadingPaneSplit(
                width: $state.width, isShown: $state.shown,
                limit: { SidebarLayout.width(proposed: $0, total: $1) },
                collapseWidth: SidebarLayout.collapseWidth,
                dividerID: "sidebar-divider", dividerLabel: "Sidebar width",
                revealID: "sidebar-reveal-edge", revealLabel: "Drag to show the sidebar"
            ) {
                PatientsListView(
                    selectedPatient: $selected, search: search, searchFocused: $focused,
                    onOpenSearchResult: { _ in }, onOpenSettings: {}, onEditProfile: { _ in })
            } content: {
                SearchHomeView(model: search, onOpen: { _ in }, isFocused: $homeFocused)
            }
            .environmentObject(appModel)
            .environmentObject(settings)
        }
    }

    private var tempRoot: URL!
    private var originalDataRoot: URL?
    private var window: NSWindow!
    private var state: Visibility!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let settings = AppSettings.shared
        originalDataRoot = settings.dataRootURL
        settings.dataRootURL = tempRoot
        let root = tempRoot!
        let appModel = AppModel(
            settings: settings, encryption: EncryptionManager(dataRootProvider: { root }),
            spotlightIndexer: NoopSpotlightIndexer())
        state = Visibility()
        let controller = NSHostingController(rootView: Host(appModel: appModel, settings: settings, state: state))
        window = TestWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 500))
        window.makeKeyAndOrderFront(nil)
        settle()
    }

    override func tearDown() async throws {
        SessionSearch.index = SearchIndex()   // AppModel pointed it at this test's folder
        window.orderOut(nil)
        window = nil
        AppSettings.shared.dataRootURL = originalDataRoot
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }

    private func source(_ path: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    private func assertNothingOverflows(_ note: String, file: StaticString = #filePath, line: UInt = #line) {
        // The host has no toolbar of its own, which trivially has nothing to overflow.
        guard let toolbar = window.toolbar else { return }
        let hidden = toolbar.items.filter { item in
            !(toolbar.visibleItems ?? []).contains(item)
        }
        XCTAssertTrue(hidden.isEmpty, "\(note): overflowing \(hidden.map(\.itemIdentifier.rawValue))", file: file, line: line)
    }

    func testNothingOverflowsAtANarrowWidthExpandedOrCollapsed() {
        assertNothingOverflows("sidebar shown, 700pt")
        state.shown = false
        settle()
        assertNothingOverflows("sidebar collapsed, 700pt")
        state.shown = true
        settle()
        assertNothingOverflows("sidebar shown again")
    }

    private var grip: PaneDividerGripView? {
        func walk(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(walk) }
        return walk(window.contentView!).lazy.compactMap { $0 as? PaneDividerGripView }.first
    }

    private var dividerIsShown: Bool { grip?.accessibilityIdentifier() == "sidebar-divider" }

    private func drag(by points: CGFloat) {
        grip?.onDrag(points)
        settle()
        grip?.onEnd()
        settle()
    }

    func testDraggingTheEdgeFarLeftCollapsesAndKeepsTheWidthItHad() {
        state.width = 300
        settle()
        drag(by: -250)
        XCTAssertFalse(state.shown)
        XCTAssertEqual(state.width, 300)
    }

    private var edgeX: CGFloat? {
        grip.map { $0.convert($0.bounds, to: nil).minX + PaneDivider.gripLead }
    }

    /// Short of collapsing, the edge still gives way under the narrowest width,
    /// so the drag shows where it is heading, and springs back when let go.
    func testDraggingUnderTheNarrowestGivesWayThenSpringsBack() throws {
        state.width = 280
        settle()
        grip?.onDrag(-120)
        settle()
        XCTAssertTrue(state.shown)
        let held = try XCTUnwrap(edgeX)
        XCTAssertLessThan(held, SidebarLayout.minWidth - 10, "the edge follows the mouse under the narrowest")
        XCTAssertGreaterThan(held, 280 - 120, "with resistance")
        grip?.onEnd()
        settle()
        XCTAssertTrue(state.shown)
        XCTAssertEqual(state.width, Double(SidebarLayout.minWidth))
        XCTAssertEqual(try XCTUnwrap(edgeX), SidebarLayout.minWidth, accuracy: 1)
    }

    func testDraggingFromTheWindowEdgeBringsTheSidebarBack() {
        state.shown = false
        settle()
        XCTAssertEqual(grip?.accessibilityIdentifier(), "sidebar-reveal-edge")
        drag(by: 40)
        XCTAssertFalse(state.shown, "a short drag from the edge leaves it hidden")
        drag(by: 230)
        XCTAssertTrue(state.shown)
        XCTAssertEqual(state.width, 230)
    }

    /// A drag that collapses the pane moves the grip out from under the mouse;
    /// let go there, the edge goes dark instead of staying lit.
    func testTheEdgeGoesDarkWhenLetGoAwayFromIt() throws {
        let view = PaneDividerGripView(frame: NSRect(x: 0, y: 0, width: 6, height: 400))
        window.contentView?.addSubview(view)
        var lit = false
        view.onActive = { lit = $0 }
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: 200), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseEntered(with: try event(.mouseMoved, x: 3))
        view.mouseDown(with: try event(.leftMouseDown, x: 3))
        XCTAssertTrue(lit)
        view.mouseUp(with: try event(.leftMouseUp, x: 200))
        XCTAssertFalse(lit, "no exit event comes when the grip moves away, so letting go checks")
        view.removeFromSuperview()
    }

    func testHidingTheSidebarRemovesItsEdgeAndShowingBringsItBack() {
        XCTAssertTrue(dividerIsShown)
        state.shown = false
        settle()
        XCTAssertFalse(dividerIsShown)
        state.shown = true
        settle()
        XCTAssertTrue(dividerIsShown)
    }

    func testTheTitleBarToggleIsTheOneWayBackFromTheHome() throws {
        XCTAssertFalse(try source("Sources/App/Views/SearchHomeView.swift").contains("sidebar.leading"),
                       "the home adds no sidebar button of its own")
    }

    func testDraggingFarPastTheNarrowestWidthCollapses() {
        XCTAssertEqual(SidebarLayout.collapseWidth, SidebarLayout.minWidth / 2)
        XCTAssertLessThan(SidebarLayout.collapseWidth, SidebarLayout.minWidth)
    }

    func testTheAppHasTheSidebarCommandAndTheToggleIsTheOnlyToolbarItem() throws {
        let app = try source("Sources/App/AletheiaApp.swift")
        XCTAssertTrue(app.contains("CommandGroup(replacing: .sidebar)"))
        XCTAssertTrue(app.contains(".keyboardShortcut(AppHotkey.toggleSidebar)"))
        let root = try source("Sources/App/Views/RootView.swift")
        XCTAssertTrue(root.contains("LeadingPaneSplit("))
        XCTAssertEqual(root.components(separatedBy: "ToolbarItem").count - 1, 1,
                       "only the sidebar toggle, so nothing pushes it into overflow")
    }

    func testTheSidebarToggleNamesWhatItWillDo() {
        XCTAssertEqual(SidebarToggle.title(shown: true), "Hide Sidebar")
        XCTAssertEqual(SidebarToggle.title(shown: false), "Show Sidebar")
    }

    // MARK: Width

    func testTheWidthStaysWithinItsLimits() {
        XCTAssertEqual(SidebarLayout.width(proposed: 0), SidebarLayout.minWidth)
        XCTAssertEqual(SidebarLayout.width(proposed: 10_000), SidebarLayout.maxWidth)
        XCTAssertEqual(SidebarLayout.width(proposed: 300), 300)
    }

    func testANarrowWindowNarrowsTheSidebarFirstButNeverBelowItsMinimum() {
        let roomy = SidebarLayout.maxWidth + SidebarLayout.contentMinWidth + 200
        XCTAssertEqual(SidebarLayout.width(proposed: 400, total: roomy), 400)
        let tight = SidebarLayout.contentMinWidth + 250
        XCTAssertEqual(SidebarLayout.width(proposed: 400, total: tight), 250)
        XCTAssertEqual(SidebarLayout.width(proposed: 400, total: 300), SidebarLayout.minWidth)
    }
}
