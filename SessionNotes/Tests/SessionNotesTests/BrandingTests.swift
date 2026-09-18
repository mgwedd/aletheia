import XCTest
@testable import SessionNotes

/// The app's user-facing name is Aletheia (the Xcode target/scheme stay
/// `SessionNotes` by design). The macOS app menu, the app switcher, and the
/// About box read `CFBundleName`/`CFBundleDisplayName`, so a regression there
/// shows up as "SessionNotes" in the menu bar — the papercut we fixed. This
/// reads the *built* app's processed Info.plist (next to the test bundle in the
/// products dir), so it locks the branding of what actually ships.
final class BrandingTests: XCTestCase {
    /// Finds the built `.app` sitting alongside the test bundle and returns its
    /// Info.plist. Skips (rather than falsely failing) if the app bundle can't be
    /// located — e.g. an unusual build layout — since the intent is a guard, not
    /// a flake.
    private func appInfoPlist() throws -> [String: Any] {
        var dir = Bundle(for: BrandingTests.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<4 {
            if let app = try? FileManager.default
                .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) {
                let plistURL = app.appendingPathComponent("Contents/Info.plist")
                if let data = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                   let dict = plist as? [String: Any] {
                    return dict
                }
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate the built .app bundle to read Info.plist")
    }

    func testUserFacingNameIsAletheia() throws {
        let plist = try appInfoPlist()
        XCTAssertEqual(plist["CFBundleName"] as? String, "Aletheia",
                       "CFBundleName drives the app menu title — it must read Aletheia")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Aletheia",
                       "CFBundleDisplayName drives the Finder/app-switcher name")
    }
}
