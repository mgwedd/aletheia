import AppKit
import Dispatch

/// Routes the quit signals a Mac sends an app (`kill <pid>`, a logout or
/// restart that falls back to SIGTERM, Ctrl-C in Terminal, a closed Terminal
/// window) into the normal quit, so the app winds down as it does for ⌘Q
/// instead of dying with work half done.
@MainActor
enum QuitSignals {
    static let handled: [Int32] = [SIGTERM, SIGINT, SIGHUP]
    /// What a quit signal does; the normal quit (tests swap it).
    static var onSignal: @MainActor () -> Void = { quit(attempt: 0) }
    /// How many times a quit AppKit ignores is asked again before the app
    /// winds down and exits on its own.
    static let retries = 30
    static let retryInterval: TimeInterval = 0.1
    private static var sources: [DispatchSourceSignal] = []

    /// Installs once; later calls do nothing.
    static func install() {
        guard sources.isEmpty else { return }
        sources = handled.map { number in
            // Without the default action the signal only wakes the source below.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            // From a run-loop timer, not this queue block: the quit waits on
            // main-actor work, which can't run while this block is.
            source.setEventHandler { schedule(after: 0) { QuitSignals.onSignal() } }
            source.resume()
            return source
        }
    }

    /// AppKit ignores a quit while a sheet is open, and for a moment after it
    /// closes. A quit that starts never returns here, so returning means it
    /// was ignored: close sheets and ask again.
    private static func quit(attempt: Int) {
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
        guard attempt < retries else { return windDownAndExit() }
        schedule(after: retryInterval) { quit(attempt: attempt + 1) }
    }

    /// The quit's own steps, for when AppKit never starts it.
    private static func windDownAndExit() {
        Task { @MainActor in
            _ = await AppLifecycle.shutdown?.shutDown()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
            exit(0)
        }
    }

    private static func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { work() } }
        RunLoop.main.add(timer, forMode: .common)
    }
}
