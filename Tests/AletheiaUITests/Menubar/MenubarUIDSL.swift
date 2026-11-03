import AppKit
import XCTest

/// How the app went away after it was asked to quit.
struct QuitResult {
    /// Whether it was gone before the wait ran out.
    let exited: Bool
    /// Crash reports for Aletheia written since the quit was asked for.
    let crashReports: [String]
}

extension Given {
    /// Sam Lee with a session, the app open.
    func theAppOpenWithASession() {
        app.seed {
            $0.license = "test"
            $0.fileVault = "on"
            $0.patients = [.init(name: "Sam Lee", sessions: 1)]
        }
        app.ensureLaunched()
    }
}

extension When {
    func pressCommandQ() -> QuitResult {
        let asked = Date()
        app.app.typeKey("q", modifierFlags: .command)
        return QuitResult.waiting(for: app, since: asked)
    }

    /// What `kill <pid>` from Terminal does.
    func sendTheQuitSignalFromTerminal() -> QuitResult {
        let asked = Date()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.astrealabs.aletheia")
        for instance in running { kill(instance.processIdentifier, SIGTERM) }
        guard !running.isEmpty else { return QuitResult(exited: false, crashReports: ["no running app to signal"]) }
        return QuitResult.waiting(for: app, since: asked)
    }
}

extension QuitResult {
    static func waiting(for driver: AppDriver, since asked: Date) -> QuitResult {
        let exited = driver.app.wait(for: .notRunning, timeout: AppDriver.timeout)
        // The crash reporter writes a few seconds after the process dies.
        Thread.sleep(forTimeInterval: 5)
        return QuitResult(exited: exited, crashReports: crashReports(since: asked))
    }

    private static func crashReports(since date: Date) -> [String] {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { url in
            guard url.lastPathComponent.hasPrefix("Aletheia"),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return false }
            return modified >= date
        }.map(\.lastPathComponent)
    }
}

extension Then where Subject == QuitResult {
    func closedWithoutACrashReport() {
        expect(subject.exited, "the app was still running after it was asked to quit")
        expect(subject.crashReports.isEmpty, "crash reports written: \(subject.crashReports.joined(separator: ", "))")
    }
}
