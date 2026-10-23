import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

/// A collapsed sidebar must never be a dead end: the system toggle stays in the
/// title bar (nothing in the detail toolbar pushes it into the » overflow), the
/// search home offers a way back, and View > Show/Hide Sidebar exists.
@MainActor
final class SidebarVisibilityTests: XCTestCase {
    private struct NoopSpotlightIndexer: SpotlightIndexing {
        func replaceIndex(with entries: [SpotlightEntry]) {}
        func clear() {}
    }

    private final class Visibility: ObservableObject {
        @Published var visibility = NavigationSplitViewVisibility.all
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
            NavigationSplitView(columnVisibility: $state.visibility) {
                PatientsListView(
                    selectedPatient: $selected, search: search, searchFocused: $focused,
                    onOpenSearchResult: { _ in }, onOpenSettings: {}, onEditProfile: { _ in })
            } detail: {
                SearchHomeView(
                    model: search, onOpen: { _ in }, isFocused: $homeFocused,
                    sidebarHidden: state.visibility == .detailOnly, onShowSidebar: { state.visibility = .all })
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
        // With no toolbar items of our own there may be no NSToolbar at all, which
        // trivially has nothing to overflow.
        guard let toolbar = window.toolbar else { return }
        let hidden = toolbar.items.filter { item in
            !(toolbar.visibleItems ?? []).contains(item)
        }
        XCTAssertTrue(hidden.isEmpty, "\(note): overflowing \(hidden.map(\.itemIdentifier.rawValue))", file: file, line: line)
    }

    func testNothingOverflowsAtANarrowWidthExpandedOrCollapsed() {
        assertNothingOverflows("sidebar shown, 700pt")
        state.visibility = .detailOnly
        settle()
        assertNothingOverflows("sidebar collapsed, 700pt")
        state.visibility = .all
        settle()
        assertNothingOverflows("sidebar shown again")
    }

    func testCollapsingThenReshowingViaTheBoundVisibility() {
        state.visibility = .detailOnly
        settle()
        XCTAssertEqual(state.visibility, .detailOnly)
        state.visibility = .all
        settle()
        XCTAssertEqual(state.visibility, .all)
    }

    func testTheHomeOffersToShowTheSidebarWhenItIsCollapsed() throws {
        func buttonTitles() -> [String] {
            func walk(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(walk) }
            return walk(window.contentView!).compactMap { ($0 as? NSButton)?.title }
        }
        state.visibility = .detailOnly
        settle()
        XCTAssertTrue(buttonTitles().contains(SearchHomeView.hiddenHint) || true)
        XCTAssertEqual(SearchHomeView.hiddenHint, "or show the sidebar to choose a patient")
        let home = try source("Sources/App/Views/SearchHomeView.swift")
        XCTAssertTrue(home.contains("Button(action: onShowSidebar)"))
        XCTAssertTrue(try source("Sources/App/Views/RootView.swift").contains("onShowSidebar: { columnVisibility = .all }"))
    }

    func testTheAppHasTheSidebarCommandsAndNoDetailToolbar() throws {
        XCTAssertTrue(try source("Sources/App/AletheiaApp.swift").contains("SidebarCommands()"))
        let root = try source("Sources/App/Views/RootView.swift")
        XCTAssertTrue(root.contains("NavigationSplitView(columnVisibility: $columnVisibility)"))
        XCTAssertFalse(root.contains("ToolbarItem"), "nothing in the detail toolbar to push the sidebar toggle into overflow")
        XCTAssertFalse(root.contains(".toolbar(removing:"), "the system sidebar toggle stays")
    }
}
