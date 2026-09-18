import XCTest
@testable import SessionNotes

/// The app's user-facing name is Aletheia (the Xcode target/scheme stay
/// `SessionNotes` by design). The macOS app menu, the app switcher, and the
/// About box read `CFBundleName`/`CFBundleDisplayName`, so a regression there
/// shows up as "SessionNotes" in the menu bar — exactly the papercut we fixed.
/// This locks both keys so a future project regeneration can't quietly drop them.
final class BrandingTests: XCTestCase {
    /// Loads the app Info.plist from source, located relative to this test file
    /// so it doesn't depend on how the test bundle is packaged.
    private func infoPlist() throws -> [String: Any] {
        // .../SessionNotes/Tests/SessionNotesTests/BrandingTests.swift
        let sessionNotesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SessionNotesTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SessionNotes
        let plistURL = sessionNotesDir
            .appendingPathComponent("Sources/SessionNotesApp/Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any], "Info.plist should be a dictionary")
    }

    func testUserFacingNameIsAletheia() throws {
        let plist = try infoPlist()
        XCTAssertEqual(plist["CFBundleName"] as? String, "Aletheia",
                       "CFBundleName drives the app menu title — it must read Aletheia")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Aletheia",
                       "CFBundleDisplayName drives the Finder/app-switcher name")
    }
}
