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

    private struct Variant {
        let label: String
        let appearance: NSAppearance
        let isHighContrast: Bool
    }

    /// Light and dark always; the Increase Contrast variants when this macOS
    /// can construct them by name.
    private func variants() throws -> [Variant] {
        var out = [
            Variant(label: "light", appearance: try XCTUnwrap(NSAppearance(named: .aqua)), isHighContrast: false),
            Variant(label: "dark", appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)), isHighContrast: false),
        ]
        if let hc = NSAppearance(named: .accessibilityHighContrastAqua) {
            out.append(Variant(label: "light, increased contrast", appearance: hc, isHighContrast: true))
        }
        if let hc = NSAppearance(named: .accessibilityHighContrastDarkAqua) {
            out.append(Variant(label: "dark, increased contrast", appearance: hc, isHighContrast: true))
        }
        return out
    }

    func testContrastHelperMatchesKnownValues() {
        let black = RGB(r: 0, g: 0, b: 0), white = RGB(r: 1, g: 1, b: 1)
        XCTAssertEqual(contrast(black, white), 21, accuracy: 0.01)
        XCTAssertEqual(contrast(white, white), 1, accuracy: 0.001)
    }

    func testEveryTokenResolvesInEveryAppearance() throws {
        for variant in try variants() {
            for token in Theme.all {
                XCTAssertNoThrow(try resolve(token, in: variant.appearance), "\(token.name) (\(variant.label))")
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
        for variant in try variants() {
            for pairing in Theme.pairings where variant.isHighContrast || !pairing.highContrastOnly {
                let ratio = contrast(
                    try resolve(pairing.foreground, in: variant.appearance),
                    try resolve(pairing.background, in: variant.appearance)
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
        guard let hcDark = NSAppearance(named: .accessibilityHighContrastDarkAqua),
              let hcLight = NSAppearance(named: .accessibilityHighContrastAqua) else {
            throw XCTSkip("Increase Contrast appearances can't be constructed on this macOS")
        }
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        for token in [Theme.line, Theme.muted] {
            let panelDark = try resolve(Theme.panel, in: dark)
            XCTAssertGreaterThan(
                contrast(try resolve(token, in: hcDark), panelDark),
                contrast(try resolve(token, in: dark), panelDark),
                "\(token.name) (dark)"
            )
            let panelLight = try resolve(Theme.panel, in: light)
            XCTAssertGreaterThan(
                contrast(try resolve(token, in: hcLight), panelLight),
                contrast(try resolve(token, in: light), panelLight),
                "\(token.name) (light)"
            )
        }
    }

    func testTokenListCoversTheCatalog() throws {
        // Every colorset in Assets.xcassets/Theme is reachable through `Theme`,
        // so the contrast tests see the whole palette.
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Resources/Assets.xcassets/Theme")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder.path), "source tree not available to the test runner")
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
