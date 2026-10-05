import AppKit

/// Deep links into the System Settings privacy panes and the Ollama download,
/// so the setup flow can send the user straight to the right place instead of
/// describing a menu path.
enum SystemSettingsLinks {
    static let ollamaDownload = URL(string: "https://ollama.com/download")!

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openCalendarSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    }

    static func openRemindersSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
    }

    static func openFileVaultSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?FileVault")
    }

    static func openOllamaDownload() {
        NSWorkspace.shared.open(ollamaDownload)
    }

    /// Best-effort deep link to the Apple Intelligence & Siri pane. The pane
    /// anchor isn't a stable public API, so if it doesn't resolve the OS falls
    /// back to opening System Settings; the on-screen text names the path either
    /// way.
    static func openAppleIntelligenceSettings() {
        open("x-apple.systempreferences:com.apple.Siri-Settings.extension")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}
