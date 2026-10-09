import XCTest
import AppKit
@testable import Aletheia

final class ThemeTests: XCTestCase {
    private struct RGB: Equatable {
        let r: Double, g: Double, b: Double

        /// WCAG 2.x relative luminance.
        var luminance: Double {
            func channel(_ c: Double) -> Double {
                c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }
    }

    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (hi, lo) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// The token as drawn under `appearance`, in sRGB.
    private func resolve(_ token: Theme.ColorToken, in appearance: NSAppearance) throws -> RGB {
        let color = try XCTUnwrap(NSColor(named: token.name, bundle: Theme.bundle), "\(token.name) is not in the asset catalog")
        var rgb: RGB?
        appearance.performAsCurrentDrawingAppearance {
            if let srgb = color.usingColorSpace(.sRGB) {
                rgb = RGB(r: Double(srgb.redComponent), g: Double(srgb.greenComponent), b: Double(srgb.blueComponent))
            }
        }
        return try XCTUnwrap(rgb, "\(token.name) has no sRGB value")
    }

    // MARK: Asset catalog source

    /// The asset catalog in the source tree. Increase Contrast values are read
    /// from here: an `NSAppearance` built by name for the high-contrast
    /// appearances resolves to the standard entries outside a real Increase
    /// Contrast session, so it can't be used to check them.
    private static let catalog = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/App/Resources/Assets.xcassets")

    private func requireCatalog() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.catalog.path), "source tree not available to the test runner")
    }

    /// The token's value as written in its colorset for the given luminosity
    /// and contrast, falling back the way the catalog does: a missing
    /// high-contrast entry uses the standard one, a missing dark entry the
    /// light one.
    private func catalogValue(_ token: Theme.ColorToken, dark: Bool, highContrast: Bool) throws -> RGB {
        let url = Self.catalog.appendingPathComponent(token.name + ".colorset/Contents.json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(root["colors"] as? [[String: Any]], "\(token.name) has no colors")

        func traits(_ entry: [String: Any]) -> (dark: Bool, high: Bool) {
            let appearances = entry["appearances"] as? [[String: String]] ?? []
            return (
                appearances.contains { $0["appearance"] == "luminosity" && $0["value"] == "dark" },
                appearances.contains { $0["appearance"] == "contrast" && $0["value"] == "high" }
            )
        }
        func component(_ value: Any?) throws -> Double {
            let text = try XCTUnwrap(value as? String, "\(token.name) has a non-string component")
            if text.hasPrefix("0x") {
                return Double(try XCTUnwrap(Int(text.dropFirst(2), radix: 16))) / 255
            }
            return try XCTUnwrap(Double(text))
        }

        let wanted: [(Bool, Bool)] = [(dark, highContrast), (dark, false), (false, highContrast), (false, false)]
        for (d, h) in wanted {
            if let entry = entries.first(where: { let t = traits($0); return t.dark == d && t.high == h }) {
                let color = try XCTUnwrap(entry["color"] as? [String: Any])
                XCTAssertEqual(color["color-space"] as? String, "srgb", "\(token.name) is not sRGB")
                let parts = try XCTUnwrap(color["components"] as? [String: Any])
                return RGB(r: try component(parts["red"]), g: try component(parts["green"]), b: try component(parts["blue"]))
            }
        }
        throw XCTSkip("\(token.name) has no usable entry")
    }

    private struct Variant {
        let label: String
        let dark: Bool
        let highContrast: Bool
    }

    private static let variants: [Variant] = [
        Variant(label: "light", dark: false, highContrast: false),
        Variant(label: "dark", dark: true, highContrast: false),
        Variant(label: "light, increased contrast", dark: false, highContrast: true),
        Variant(label: "dark, increased contrast", dark: true, highContrast: true),
    ]

    func testContrastHelperMatchesKnownValues() {
        let black = RGB(r: 0, g: 0, b: 0), white = RGB(r: 1, g: 1, b: 1)
        XCTAssertEqual(contrast(black, white), 21, accuracy: 0.01)
        XCTAssertEqual(contrast(white, white), 1, accuracy: 0.001)
    }

    func testEveryTokenResolvesInLightAndDark() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for token in Theme.all {
                XCTAssertNoThrow(try resolve(token, in: appearance), "\(token.name) (\(name.rawValue))")
            }
        }
    }

    func testCatalogSourceMatchesWhatTheAppLoads() throws {
        // Ties the JSON reader below to the compiled catalog, so the Increase
        // Contrast checks read the same colors the app draws.
        try requireCatalog()
        let pairs: [(NSAppearance.Name, Bool)] = [(.aqua, false), (.darkAqua, true)]
        for (name, dark) in pairs {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for token in Theme.all {
                let loaded = try resolve(token, in: appearance)
                let source = try catalogValue(token, dark: dark, highContrast: false)
                XCTAssertEqual(loaded.r, source.r, accuracy: 1.5 / 255, "\(token.name) red (\(name.rawValue))")
                XCTAssertEqual(loaded.g, source.g, accuracy: 1.5 / 255, "\(token.name) green (\(name.rawValue))")
                XCTAssertEqual(loaded.b, source.b, accuracy: 1.5 / 255, "\(token.name) blue (\(name.rawValue))")
            }
        }
    }

    func testEveryTokenHasADarkValue() throws {
        // A colorset missing its dark entry falls back to the light one, which
        // is unreadable on dark surfaces. Ink that is white in both is fine.
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        for token in Theme.all where token != Theme.recordingInk {
            XCTAssertNotEqual(try resolve(token, in: light), try resolve(token, in: dark), "\(token.name) is the same in light and dark")
        }
    }

    func testEveryPairingMeetsItsContrast() throws {
        try requireCatalog()
        for variant in Self.variants {
            for pairing in Theme.pairings where variant.highContrast || !pairing.highContrastOnly {
                let ratio = contrast(
                    try catalogValue(pairing.foreground, dark: variant.dark, highContrast: variant.highContrast),
                    try catalogValue(pairing.background, dark: variant.dark, highContrast: variant.highContrast)
                )
                XCTAssertGreaterThanOrEqual(
                    ratio, pairing.minimum,
                    "\(pairing.foreground.name) on \(pairing.background.name) (\(variant.label)) is \(String(format: "%.2f", ratio)):1"
                )
            }
        }
    }

    func testDarkSurfacesAreDarkerThanTheirInk() throws {
        // Catches a swapped light/dark pair.
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        for surface in [Theme.window, Theme.sidebar, Theme.panel, Theme.field] {
            XCTAssertLessThan(try resolve(surface, in: dark).luminance, try resolve(Theme.text, in: dark).luminance)
            XCTAssertGreaterThan(try resolve(surface, in: light).luminance, try resolve(Theme.text, in: light).luminance)
        }
    }

    func testIncreaseContrastStrengthensBordersAndSecondaryText() throws {
        try requireCatalog()
        for token in [Theme.line, Theme.muted] {
            for dark in [false, true] {
                let panel = try catalogValue(Theme.panel, dark: dark, highContrast: false)
                XCTAssertGreaterThan(
                    contrast(try catalogValue(token, dark: dark, highContrast: true), panel),
                    contrast(try catalogValue(token, dark: dark, highContrast: false), panel),
                    "\(token.name) (\(dark ? "dark" : "light"))"
                )
            }
        }
    }

    func testTokenListCoversTheCatalog() throws {
        // Every colorset in Assets.xcassets/Theme is reachable through `Theme`,
        // so the contrast tests see the whole palette.
        try requireCatalog()
        let folder = Self.catalog.appendingPathComponent("Theme")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".colorset") }
            .map { "Theme/" + $0.replacingOccurrences(of: ".colorset", with: "") }
        XCTAssertEqual(Set(names), Set(Theme.all.map(\.name)).subtracting(["AccentColor"]))
        XCTAssertEqual(Theme.all.count, Set(Theme.all).count, "a token is listed twice")
    }
}

final class AppearancePreferenceTests: XCTestCase {
    func testRawValuesAreStable() {
        // Persisted in UserDefaults; renaming a case would reset everyone's choice.
        XCTAssertEqual(AppearancePreference.allCases.map(\.rawValue), ["system", "light", "dark"])
        XCTAssertEqual(AppearancePreference.default, .system)
    }

    func testMapsToAppKitAppearances() {
        XCTAssertNil(AppearancePreference.system.appearanceName)
        XCTAssertEqual(AppearancePreference.light.appearanceName, .aqua)
        XCTAssertEqual(AppearancePreference.dark.appearanceName, .darkAqua)
    }

    @MainActor
    func testApplySetsAndClearsTheAppWideAppearance() {
        let original = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = original }

        AppearancePreference.dark.apply()
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
        AppearancePreference.light.apply()
        XCTAssertEqual(NSApplication.shared.appearance?.name, .aqua)
        AppearancePreference.system.apply()
        XCTAssertNil(NSApplication.shared.appearance)
    }
}
