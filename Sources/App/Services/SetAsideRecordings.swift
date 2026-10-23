import AppKit
import Foundation

/// Recordings the launch sweep set aside because their session couldn't be
/// found in this data folder (`Staging/quarantine/`). They stay unencrypted
/// until they're recovered or deleted, so the app warns while any are there.
///
/// The list re-checks the folder whenever the app becomes active and whenever
/// a sweep or a recovery may have changed it, so the warning clears however
/// the recordings were dealt with.
@MainActor
final class SetAsideRecordings: ObservableObject {
    static let shared = SetAsideRecordings()

    struct Item: Identifiable, Equatable {
        let folder: URL
        /// The session it was recorded for, when the folder name carries one.
        let sessionID: UUID?
        let modified: Date?
        let byteCount: Int64

        var id: String { folder.lastPathComponent }
    }

    @Published private(set) var items: [Item] = []

    let stagingRoot: URL
    private var observers: [NSObjectProtocol] = []

    var quarantineDir: URL { OrphanAudioSweep.quarantineDirectory(stagingRoot: stagingRoot) }

    init(stagingRoot: URL = Store.stagingDirectoryURL, center: NotificationCenter = .default) {
        self.stagingRoot = stagingRoot
        for name in [Notification.Name.setAsideRecordingsMayHaveChanged, NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.refresh() }
                } else {
                    DispatchQueue.main.async { self?.refresh() }
                }
            })
        }
        refresh()
    }

    /// The warning's text: a count only, never a name.
    static func warningText(count: Int) -> String {
        let subject = count == 1 ? "1 recording couldn't be matched to a session and is" : "\(count) recordings couldn't be matched to a session and are"
        return "\(subject) set aside on this Mac, unencrypted, until you recover or delete \(count == 1 ? "it" : "them")."
    }

    /// Re-reads the set-aside folder. Folders with no recording in them don't count.
    func refresh() {
        let fm = FileManager.default
        let found: [Item] = OrphanAudioSweep.directories(in: quarantineDir).compactMap { folder in
            let files = ["mic.caf", "call.caf"].map { folder.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
            guard !files.isEmpty else { return nil }
            let values = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) }
            return Item(
                folder: folder,
                sessionID: UUID(uuidString: String(folder.lastPathComponent.prefix(36))),
                modified: values.compactMap(\.contentModificationDate).max(),
                byteCount: values.reduce(0) { $0 + Int64($1.fileSize ?? 0) }
            )
        }
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        if found != items { items = found }
    }

    /// Deletes a set-aside recording for good (after the user confirmed).
    func delete(_ item: Item, audit: AuditLog?) throws {
        try FileManager.default.removeItem(at: item.folder)
        audit?.record(.recordDeleted, subjectID: item.sessionID?.uuidString, detail: "set-aside recording")
        refresh()
    }
}
