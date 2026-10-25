@testable import Aletheia
import Foundation
import XCTest

// MARK: - Subjects

/// Which shipped executable a check looks at.
enum ShippedPart {
    case app
    case networkHelper
}

/// The entitlements a shipped part is signed with.
struct SignedEntitlements {
    let granted: Set<String>
}

/// A purpose-string table: the keys of the app's Info.plist.
struct InfoPlist {
    let keys: Set<String>
    let version: String
}

/// What the app bundle carries.
struct BundleContents {
    let paths: [String]
}

/// Source files of the app, as shipped.
struct AppSource {
    let files: [(path: String, lines: [String])]
}

/// A downloaded model file on disk and the checksum it is pinned to.
struct DownloadedModel {
    let file: URL
    let pinned: String
}

private enum Repo {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func file(_ path: String) -> URL { root.appendingPathComponent(path) }
}

// MARK: - When

extension When {
    /// `codesign -d --entitlements -` on the Release build: the entitlements
    /// project.yml signs that part with.
    func readReleaseEntitlements(of part: ShippedPart) throws -> SignedEntitlements {
        var path = "Sources/NetworkHelper/NetworkHelper.entitlements"
        if part == .app {
            let yml = try String(contentsOf: Repo.file("project.yml"), encoding: .utf8)
            let match = try XCTUnwrap(
                yml.range(of: #"Release:\s*\n\s*CODE_SIGN_ENTITLEMENTS:\s*(\S+)"#, options: .regularExpression),
                "project.yml signs no Release entitlements")
            path = String(yml[match].split(whereSeparator: { $0.isWhitespace }).last!)
        }
        let data = try Data(contentsOf: Repo.file(path))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return SignedEntitlements(granted: Set(plist.filter { ($0.value as? Bool) == true }.keys))
    }

    /// `plutil -p Info.plist` on the Release build: the template with the
    /// developer-only blocks left out, as the production build is preprocessed.
    func readReleaseInfoPlist() throws -> InfoPlist {
        let text = try String(contentsOf: Repo.file("Sources/App/Resources/Info.plist"), encoding: .utf8)
        var kept: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("#ifdef ALETHEIA_DEV") { skipping = true; continue }
            if line.hasPrefix("#endif") { skipping = false; continue }
            if !skipping { kept.append(line) }
        }
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(kept.joined(separator: "\n").utf8), format: nil)
                as? [String: Any])
        return InfoPlist(keys: Set(plist.keys), version: plist["CFBundleShortVersionString"] as? String ?? "")
    }

    /// The version Settings shows.
    func settingsVersion() -> String { AppSettings.appVersionString }

    /// What the build under test composes.
    func featuresInThisBuild() -> FeatureRegistry { app.appModel.featureRegistry }

    /// `ls -R` on the app bundle's Contents, without the test bundle.
    func listBundleContents() -> BundleContents {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let walker = FileManager.default.enumerator(at: contents, includingPropertiesForKeys: nil)
        let paths = (walker?.allObjects as? [URL] ?? [])
            .map { $0.path.replacingOccurrences(of: contents.path + "/", with: "") }
            .filter { !$0.hasPrefix("PlugIns/") }
        return BundleContents(paths: paths)
    }

    /// The Swift files the app target is built from.
    func readAppSource() -> AppSource {
        let sources = Repo.file("Sources/App")
        let urls = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
        return AppSource(files: urls.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (path: url.path.replacingOccurrences(of: Repo.root.path + "/", with: ""),
                    lines: text.components(separatedBy: "\n"))
        })
    }

    /// A model file downloaded to disk, pinned to the `shasum -a 256` of its bytes.
    func downloadModel(bytes: Int = 4_096) throws -> DownloadedModel {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString).gguf")
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: file)
        return DownloadedModel(file: file, pinned: try shasum(file))
    }

    /// `truncate -s` the file to half its size.
    func cutShort(_ model: DownloadedModel) throws -> DownloadedModel {
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: model.file.path)[.size] as? Int)
        let copy = model.file.deletingLastPathComponent().appendingPathComponent("short-\(UUID().uuidString).gguf")
        try FileManager.default.copyItem(at: model.file, to: copy)
        let handle = try FileHandle(forWritingTo: copy)
        try handle.truncate(atOffset: UInt64(size / 2))
        try handle.close()
        return DownloadedModel(file: copy, pinned: model.pinned)
    }

    private func shasum(_ file: URL) throws -> String {
        let run = try Self.run("/usr/bin/shasum", ["-a", "256", file.path], in: nil)
        return String(run.output.split(separator: " ").first ?? "")
    }

    /// `ls -R` on the patient folders of the data folder, as paths below it.
    func listPatientFolders() -> [String] {
        let patients = app.root.appendingPathComponent("Patients", isDirectory: true)
        let walker = FileManager.default.enumerator(at: patients, includingPropertiesForKeys: [.isDirectoryKey])
        return (walker?.allObjects as? [URL] ?? []).map {
            $0.path.replacingOccurrences(of: patients.path + "/", with: "")
        }
    }

    /// `ls -la` on the session folder.
    func listSessionFolder(of visit: PatientSession, bench: RecordingBench) -> [String] {
        let dir = bench.store.patientDir(for: visit.patient).appendingPathComponent(visit.session.folderName)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// Accepts the terms and privacy policy, then `cat legal-acceptance.log`.
    func acceptTermsAndReadReceipt() throws -> [String] {
        app.settings.recordLegalAcceptance()
        let log = app.root.appendingPathComponent("legal-acceptance.log")
        let text = try String(contentsOf: log, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    private static func run(_ tool: String, _ args: [String], in directory: URL?) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Then

@MainActor extension Then where Subject == SignedEntitlements {
    func areExactly(_ expected: Set<String>) {
        expectEqual(subject.granted, expected, "entitlements")
    }

    func includeNoNetworkClient() {
        expect(!subject.granted.contains("com.apple.security.network.client"), "the app can reach the network")
    }
}

@MainActor extension Then where Subject == InfoPlist {
    func explainsMicrophoneAndSpeech() {
        expect(subject.keys.contains(Copy.microphonePurpose), "no microphone purpose string")
        expect(subject.keys.contains(Copy.speechPurpose), "no speech recognition purpose string")
    }

    func asksForNeitherCalendarNorReminders() {
        expect(!subject.keys.contains(Copy.calendarPurpose), "a Calendar purpose string ships")
        expect(!subject.keys.contains(Copy.remindersPurpose), "a Reminders purpose string ships")
    }

    func versionMatchesSettings(_ settingsVersion: String) {
        expectEqual(subject.version, settingsVersion, "the version Settings shows")
    }
}

@MainActor extension Then where Subject == BundleContents {
    func holdsOnlySpeechAndLanguageRuntimes() {
        // The test host injects XCTest and Swift Testing into the app's Frameworks folder; a shipped build never has them.
        let harness: (String) -> Bool = { $0.hasPrefix("XC") || $0.hasPrefix("libXCTest") || $0.hasPrefix("Testing.") || $0.hasPrefix("lib_Testing") }
        let frameworks = Set(subject.paths.filter { $0.hasPrefix("Frameworks/") }
            .compactMap { $0.split(separator: "/").dropFirst().first.map(String.init) }
            .filter { !harness($0) })
        let allowed: Set<String> = ["WhisperEngine.framework", "llama.framework", "whisper.framework"]
        expect(frameworks.isSubset(of: allowed), "unexpected frameworks: \(frameworks.subtracting(allowed).sorted())")
    }

    func holdsNoAnalyticsSDK() {
        let analytics = ["sentry", "firebase", "crashlytics", "mixpanel", "amplitude", "segment", "posthog", "appcenter", "bugsnag", "datadog"]
        let hits = subject.paths.filter { path in analytics.contains { path.lowercased().contains($0) } }
        expect(hits.isEmpty, "analytics code in the bundle: \(hits)")
    }

    func holdsNoModelFiles() {
        let weights: Set<String> = ["gguf", "ggml", "bin", "onnx", "mlmodel", "mlmodelc", "safetensors", "pt"]
        let hits = subject.paths.filter {
            weights.contains(($0 as NSString).pathExtension.lowercased()) && !$0.lowercased().contains("silero")
        }
        expect(hits.isEmpty, "model files in the bundle: \(hits)")
    }
}

@MainActor extension Then where Subject == AppSource {
    func keepsTheRecordingHarnessOutOfRelease() {
        let marker = "--harness-"
        let harnessFiles = subject.files.filter { $0.lines.contains { $0.contains(marker) && !$0.hasPrefix("//") } }
        expect(!harnessFiles.isEmpty, "found no harness to check")
        for file in harnessFiles {
            let code = file.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            expect(code.first == "#if DEBUG" && code.last == "#endif", "\(file.path) is not wrapped in #if DEBUG")
        }
        for file in subject.files where !harnessFiles.contains(where: { $0.path == file.path }) {
            for (index, line) in file.lines.enumerated() where line.contains("HarnessRun.") || line.contains("HarnessEval.") {
                let before = file.lines[max(0, index - 3)..<index].map { $0.trimmingCharacters(in: .whitespaces) }
                expect(before.contains("#if DEBUG"), "\(file.path):\(index + 1) calls the harness outside #if DEBUG")
            }
        }
    }

    func makesNoNetworkCalls() {
        let calls = ["URLSession", "NWConnection", "NSURLConnection", "CFSocket", "CFStream"]
        for file in subject.files {
            for (index, line) in file.lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), let call = calls.first(where: { line.contains($0) }) else { continue }
                fail("\(file.path):\(index + 1) uses \(call)")
            }
        }
    }
}

@MainActor extension Then where Subject == FeatureRegistry {
    func ships(_ ids: [String]) {
        for id in ids { expect(subject.contains(id: id), "\(id) is missing from the Release build") }
    }

    func doesNotShip(_ ids: [String]) {
        for id in ids { expect(!subject.contains(id: id), "\(id) ships in the Release build") }
    }
}

@MainActor extension Then where Subject == DownloadedModel {
    func matchesItsPinnedChecksum() {
        do { try ModelDigest.verify(fileAt: subject.file, expectedSHA256: subject.pinned) }
        catch { fail("the good file was refused: \(error)") }
    }

    func isRefused() {
        do {
            try ModelDigest.verify(fileAt: subject.file, expectedSHA256: subject.pinned)
            fail("the damaged file was accepted")
        } catch {}
    }
}

@MainActor extension Then where Subject == [String] {
    /// Patient folders by UUID, session folders by date, audio and text only.
    func areNamedByUUIDAndDateWithOnlyAudioAndText() {
        let audio: Set<String> = ["m4a", "caf", "wav", "aiff", "mp3"]
        let text: Set<String> = ["txt", "md", "json", "jsonl", "log"]
        for path in subject {
            let parts = path.split(separator: "/").map(String.init)
            if parts.count == 1 {
                expect(UUID(uuidString: parts[0]) != nil, "patient folder \(parts[0]) is not named by UUID")
            } else if parts.count == 2, (parts[1] as NSString).pathExtension.isEmpty {
                expect(parts[1].range(of: #"^\d{4}-\d{2}-\d{2}_Session(-\d+)?$"#, options: .regularExpression) != nil,
                       "session folder \(parts[1]) is not named by date")
            } else {
                let ext = (parts.last! as NSString).pathExtension.lowercased()
                expect(audio.union(text).contains(ext), "\(path) is neither audio nor text")
            }
        }
    }

    func hasNoAudio() {
        expect(!subject.contains { $0.hasSuffix(".m4a") || $0.hasSuffix(".caf") || $0.hasSuffix(".wav") },
               "audio is in the session folder: \(subject)")
    }

    func holdsOneLineWithVersionTimeAndAppVersion() {
        expectEqual(subject.count, 1, "lines in the receipt")
        guard let line = subject.first, let entry = try? JSONDecoder().decode(LegalReceipt.Entry.self, from: Data(line.utf8))
        else { return fail("the line is not readable: \(subject)") }
        expect(!entry.acceptedVersion.isEmpty, "no accepted version")
        expect(entry.acceptedAt.hasSuffix("Z"), "the time is not UTC: \(entry.acceptedAt)")
        expect(!entry.appVersion.isEmpty, "no app version")
    }
}
