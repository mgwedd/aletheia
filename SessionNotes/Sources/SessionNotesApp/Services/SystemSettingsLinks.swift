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

    static func openOllamaDownload() {
        NSWorkspace.shared.open(ollamaDownload)
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}
