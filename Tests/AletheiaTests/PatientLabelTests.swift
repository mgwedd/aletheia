import XCTest
@testable import Aletheia

final class PatientLabelTests: XCTestCase {
    func testLabelIsDottedInitials() {
        XCTAssertEqual(PatientLabel(name: "Jane Doe").text, "J.D.")
        XCTAssertEqual(PatientLabel(name: "jane").text, "J.")
        XCTAssertEqual(PatientLabel(name: "Mary Ann van Buren").text, "M.B.")
        XCTAssertEqual(PatientLabel(name: "  ").text, "?")
        XCTAssertEqual(PatientLabel(name: "").text, "?")
    }

    func testLabelNeverContainsTheName() {
        let label = PatientLabel(name: "Jane Doe").text
        XCTAssertFalse(label.contains("ane"))
        XCTAssertFalse(label.contains("oe"))
    }

    func testPatientInitializerMatchesName() {
        let id = UUID()
        let patient = Patient(id: id, name: "Jane Doe", slug: id.uuidString)
        XCTAssertEqual(PatientLabel(patient), PatientLabel(name: "Jane Doe"))
    }

    func testContinuationOpensNothingWhileLocked() {
        let id = SpotlightItemBuilder.patientIdentifier(UUID())
        XCTAssertNil(SystemSurfaceAccess.route(forIdentifier: id, isLocked: true))
        XCTAssertNotNil(SystemSurfaceAccess.route(forIdentifier: id, isLocked: false))
    }

    func testSystemSurfacesFollowTheLockMirror() {
        let prior = SystemSurfaceAccess.isLocked
        defer { SessionSearch.setAppLocked(prior) }
        SessionSearch.setAppLocked(true)
        XCTAssertTrue(SystemSurfaceAccess.isLocked)
        SessionSearch.setAppLocked(false)
        XCTAssertEqual(SystemSurfaceAccess.isLocked, !SessionSearch.mayOpenIndex)
    }

    func testDefaultIndexerIsANoOpUnderTheTestHost() {
        XCTAssertTrue(TestHost.isHostingTests())
        XCTAssertTrue(SpotlightIndexerFactory.make() is NoOpSpotlightIndexer)
        XCTAssertTrue(SpotlightIndexerFactory.make(environment: [:]) is SpotlightIndexer)
    }

    // MARK: - Surface and policy

    func testInAppAlwaysShowsTheFullName() {
        for showFull in [true, false] {
            for locked in [true, false] {
                let policy = PatientLabel.Policy(showFullName: showFull, isLocked: locked)
                XCTAssertEqual(PatientLabel.text(forName: " Jane Doe ", surface: .inApp, policy: policy), "Jane Doe")
            }
        }
    }

    func testSurfaceByPolicyMatrix() {
        for surface in PatientLabel.Surface.allCases where surface != .inApp {
            for showFull in [true, false] {
                for locked in [true, false] {
                    let policy = PatientLabel.Policy(showFullName: showFull, isLocked: locked)
                    let expected = (showFull && !locked) ? "Jane Doe" : "J.D."
                    XCTAssertEqual(PatientLabel.text(forName: "Jane Doe", surface: surface, policy: policy), expected,
                                   "\(surface) full=\(showFull) locked=\(locked)")
                }
            }
        }
    }

    func testLockForcesInitialsOnMenuBarIntentAndNotification() {
        let policy = PatientLabel.Policy(showFullName: true, isLocked: true)
        for surface in [PatientLabel.Surface.menuBar, .intent, .notification] {
            XCTAssertEqual(PatientLabel.text(forName: "Jane Doe", surface: surface, policy: policy), "J.D.")
        }
    }

    func testBlankNamesFallBackToClient() {
        for surface in PatientLabel.Surface.allCases {
            for showFull in [true, false] {
                let policy = PatientLabel.Policy(showFullName: showFull, isLocked: false)
                XCTAssertEqual(PatientLabel.text(forName: "", surface: surface, policy: policy), "Client")
                XCTAssertEqual(PatientLabel.text(forName: " \n ", surface: surface, policy: policy), "Client")
            }
        }
    }

    func testPatientOverloadMatchesName() {
        let id = UUID()
        let patient = Patient(id: id, name: "Jane Doe", slug: id.uuidString)
        let policy = PatientLabel.Policy(showFullName: false, isLocked: false)
        XCTAssertEqual(PatientLabel.text(for: patient, surface: .menuBar, policy: policy), "J.D.")
    }

    // MARK: - Menu bar

    func testMenuBarLabelIsInitialsUnlessOptedInAndUnlocked() {
        XCTAssertEqual(MenuBarContentPolicy.patientLabel(name: "Jane Doe", showFullName: false, isLocked: false), "J.D.")
        XCTAssertEqual(MenuBarContentPolicy.patientLabel(name: "Jane Doe", showFullName: true, isLocked: false), "Jane Doe")
        XCTAssertEqual(MenuBarContentPolicy.patientLabel(name: "Jane Doe", showFullName: true, isLocked: true), "J.D.")
    }

    func testPickerDisambiguatesCollidingInitialsWithoutTheName() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86_400 * 30)
        let labels = MenuBarContentPolicy.pickerLabels(
            [(a, "Jane Doe", day1), (b, "John Day", day2), (c, "Amy Lee", day1), (d, "Jack Dole", day2)],
            showFullName: false, isLocked: false)
        XCTAssertEqual(labels[c], "A.L.")
        XCTAssertNotEqual(labels[a], labels[b])
        XCTAssertNotEqual(labels[b], labels[d])
        for label in labels.values {
            for forbidden in ["Jane", "John", "Amy", "Jack", "Doe", "Day", "Lee", "Dole"] {
                XCTAssertFalse(label.contains(forbidden), label)
            }
        }
        XCTAssertTrue(labels[a]!.hasPrefix("J.D. · added"))
    }

    func testPickerNumbersRowsThatStillCollide() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let a = UUID(), b = UUID()
        let labels = MenuBarContentPolicy.pickerLabels([(a, "Jane Doe", day), (b, "John Day", day)],
                                                       showFullName: false, isLocked: false)
        XCTAssertNotEqual(labels[a], labels[b])
    }

    func testPickerShowsFullNamesWhenOptedIn() {
        let a = UUID()
        let labels = MenuBarContentPolicy.pickerLabels([(a, "Jane Doe", Date())], showFullName: true, isLocked: false)
        XCTAssertEqual(labels[a], "Jane Doe")
    }

    // MARK: - Source scan

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative), encoding: .utf8)
    }

    private func swiftFiles(under relative: String) throws -> [String] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent(relative).path)
        return names.filter { $0.hasSuffix(".swift") }.map { relative + "/" + $0 }
    }

    func testOutOfAppBuildersNeverReadAPatientName() throws {
        var files = try ["Sources/App/Services/Spotlight", "Sources/App/Intents",
                         "Sources/App/Services/Calendar", "Sources/App/Services/Reminders"]
            .flatMap(swiftFiles(under:))
        files.append("Sources/App/Services/SessionQueries.swift")
        XCTAssertGreaterThanOrEqual(files.count, 9, "the scan must find the builders")
        let banned = try NSRegularExpression(pattern: #"\.name\b|patientName"#)
        for file in files {
            let code = try source(file).split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let range = NSRange(code.startIndex..., in: code)
            XCTAssertNil(banned.firstMatch(in: code, range: range), "\(file) reads a patient name; use PatientLabel")
        }
    }

    /// Notifications and the menu bar name patients only through `PatientLabel`.
    func testNotificationsAndMenuBarNeverInterpolateAName() throws {
        var files = try swiftFiles(under: "Sources/App/Services/Notifications")
        files.append("Sources/App/Views/RecordingMenuBar.swift")
        XCTAssertGreaterThanOrEqual(files.count, 2)
        let banned = try NSRegularExpression(
            pattern: #"\\\(\s*(\w+\.)*(name|patientName|displayName)\b|\bText\(\s*(\w+\.)*(name|patientName|displayName)\s*\)"#)
        for file in files {
            let code = try source(file).split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let range = NSRange(code.startIndex..., in: code)
            XCTAssertNil(banned.firstMatch(in: code, range: range), "\(file) shows a name directly; use PatientLabel")
        }
    }
}
