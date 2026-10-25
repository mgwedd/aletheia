import AppKit
import Foundation

/// The wording shared by the copy buttons and diagram cards in chat and notes.
enum CardWords {
    static let copy = "Copy"
    static let copied = "Copied"
    static let diagramTab = "Diagram"
    static let sourceTab = "Source"
}

/// The "Copy" to "Copied" feedback of a copy button: the text goes on the
/// pasteboard, the button says "Copied" for a moment, then goes back.
@MainActor
final class CopyFeedback: ObservableObject {
    /// How long the button says "Copied".
    static let showFor: TimeInterval = 1.5

    @Published private(set) var justCopied = false
    private var reset: Task<Void, Never>?
    private let showFor: TimeInterval

    init(showFor: TimeInterval = CopyFeedback.showFor) { self.showFor = showFor }

    var title: String { justCopied ? CardWords.copied : CardWords.copy }

    /// Puts `text` on the pasteboard, as patient text that stays on this Mac.
    /// `kind` names what was copied, for the activity log.
    func copy(_ text: String, kind: AuditDetail? = nil, to pasteboard: NSPasteboard = PHIPasteboard.general) {
        PHIPasteboard.writeString(text, kind: kind, to: pasteboard)
        flash()
    }

    /// Takes the "Copied" back at once (the person clicked away).
    func dismiss() {
        reset?.cancel()
        justCopied = false
    }

    /// Says "Copied" for `showFor` seconds; a second copy restarts the count.
    func flash() {
        justCopied = true
        reset?.cancel()
        let seconds = showFor
        reset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.justCopied = false
        }
    }
}
