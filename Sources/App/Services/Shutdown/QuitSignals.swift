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
    static var onSignal: @MainActor () -> Void = { NSApp.terminate(nil) }
    private static var sources: [DispatchSourceSignal] = []

    /// Installs once; later calls do nothing.
    static func install() {
        guard sources.isEmpty else { return }
        sources = handled.map { number in
            // Without the default action the signal only wakes the source below.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { QuitSignals.onSignal() } }
            source.resume()
            return source
        }
    }
}
