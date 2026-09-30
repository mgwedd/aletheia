import Foundation

// MARK: - Probe results (plain values, so the runner is pure and testable)

/// What a look at the chosen data folder found.
struct DataFolderProbe: Equatable {
    /// nil when no folder has been chosen.
    var path: String?
    var exists = false
    var isDirectory = false
    var readable = false
    var writable = false
    /// Free space on the folder's volume, when it could be read.
    var freeBytes: Int64?
}

/// The database, from two angles: what the running app hit when it opened it,
/// and what an independent read-only look at the file found.
struct DatabaseProbe: Equatable {
    /// The failure the app recorded when it tried to open the database
    /// (`AppModel.databaseState`); nil when it opened fine.
    var appFailure: DatabaseOpenFailure?
    var inspection: DatabaseInspection
}

enum KeystoreProbe: Equatable {
    /// Encryption isn't in use for this folder — there's nothing to check.
    case notInUse
    /// The keystore file is present and readable.
    case present(unlocked: Bool)
    /// A keystore is there but can't be read/decoded.
    case unreadable
}

/// The two kinds of safety copy of the database kept inside the data folder
/// (`BackupLayout`): rolling snapshots (before updates and encryption changes)
/// and pre-migration copies (before database upgrades). Legacy folder names from
/// older installs are counted too.
struct SnapshotProbe: Equatable {
    var snapshotCount = 0
    var newestSnapshot: Date?
    var preUpgradeCount = 0
    var newestPreUpgrade: Date?

    var totalCount: Int { snapshotCount + preUpgradeCount }
    var newest: Date? { [newestSnapshot, newestPreUpgrade].compactMap { $0 }.max() }
}

/// How many patient/session entries on disk couldn't be read, from
/// `Store.scanForUnreadableEntries()`. `.notAvailable` (no store, or an encrypted
/// folder that's still locked, where every file would look unreadable) leaves the
/// check out of the report rather than showing a false "all clear" or a false alarm.
enum UnreadableEntriesProbe: Equatable {
    case notAvailable
    case count(Int)
}

struct WhisperModelFileProbe: Equatable {
    var modelName: String
    var exists: Bool
    var sizeBytes: Int64?
    /// The catalogue's approximate size, for a "does this look complete" check.
    var expectedMB: Int
}

/// Whether the transcription model's SHA-256 matches its pinned digest.
///
/// The live probe compares `ModelDigest.sha256` of the file with
/// `WhisperModel.expectedSHA256` (see `WhisperModelPins`). `.unavailable` means the
/// digest couldn't be computed (or there's no file), and no integrity check is shown.
enum WhisperDigestProbe: Equatable {
    case unavailable
    case matches
    case mismatch
}

// MARK: - The probing seam

/// Everything Doctor needs to know about the outside world, behind one seam so
/// `DoctorRunner` can be unit-tested with stubs (no real disk, SQLite or Ollama).
protocol DoctorProbing {
    func environment() -> DoctorEnvironment
    func now() -> Date
    func dataFolder() -> DataFolderProbe
    func database() -> DatabaseProbe
    func keystore() -> KeystoreProbe
    func snapshots() -> SnapshotProbe
    func unreadableEntries() -> UnreadableEntriesProbe
    func whisperModelFile() -> WhisperModelFileProbe
    func whisperModelDigest() -> WhisperDigestProbe
    /// The existing setup checks (microphone, call audio, transcription model,
    /// AI engine, …), reused from `ToolHealth` rather than re-implemented.
    func toolHealthChecks() async -> [ToolHealthCheck]
}

// MARK: - Live implementation

/// The real probes. Every read here is non-destructive: the database is opened
/// read-only, the data folder is only stat'ed, nothing is created or written,
/// and nothing touches the network except the existing Ollama check — which is
/// skipped unless Ollama's address is loopback.
struct LiveDoctorProbes: DoctorProbing {
    var dataRoot: URL?
    /// `AppModel.databaseState.failure` at the time Doctor runs.
    var appDatabaseFailure: DatabaseOpenFailure?
    var encryptionInUse: Bool
    var encryptionUnlocked: Bool
    var whisperModelPath: URL
    var whisperModelName: String
    var whisperExpectedMB: Int
    /// The pinned SHA-256 for the selected model (`WhisperModel.expectedSHA256`).
    var whisperExpectedSHA256: String
    var unreadableEntriesProvider: () -> UnreadableEntriesProbe = { .notAvailable }
    var toolHealthProvider: @MainActor () async -> [ToolHealthCheck]

    func environment() -> DoctorEnvironment { .current(dataRoot: dataRoot) }
    func now() -> Date { Date() }

    func dataFolder() -> DataFolderProbe {
        guard let root = dataRoot else { return DataFolderProbe(path: nil) }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: root.path, isDirectory: &isDirectory)
        var probe = DataFolderProbe(path: root.path)
        probe.exists = exists
        probe.isDirectory = isDirectory.boolValue
        guard exists else { return probe }
        probe.readable = fm.isReadableFile(atPath: root.path)
        probe.writable = fm.isWritableFile(atPath: root.path)
        if let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            probe.freeBytes = free
        }
        return probe
    }

    func database() -> DatabaseProbe {
        guard let root = dataRoot else {
            return DatabaseProbe(appFailure: appDatabaseFailure, inspection: .missing)
        }
        return DatabaseProbe(
            appFailure: appDatabaseFailure,
            inspection: DatabaseInspector.inspect(databaseAt: CommentStore.databaseURL(root: root))
        )
    }

    func keystore() -> KeystoreProbe {
        guard encryptionInUse, let root = dataRoot else { return .notInUse }
        return Keystore.load(from: root) == nil ? .unreadable : .present(unlocked: encryptionUnlocked)
    }

    func snapshots() -> SnapshotProbe {
        guard let root = dataRoot else { return SnapshotProbe() }
        // Read-only: look in the current `BackupLayout` folders and also the legacy
        // ones (`.snapshots/`, `Backups/`) that an older install still has until a
        // snapshot or migration folds them in. Never moves anything.
        let live = Self.scan([
            BackupLayout.directory(.snapshots, dataRoot: root),
            root.appendingPathComponent(BackupLayout.legacySnapshotsFolderName, isDirectory: true)
        ])
        let preUpgrade = Self.scan([
            BackupLayout.directory(.migrations, dataRoot: root),
            root.appendingPathComponent(BackupLayout.legacyMigrationsFolderName, isDirectory: true)
        ])
        return SnapshotProbe(
            snapshotCount: live.count, newestSnapshot: live.newest,
            preUpgradeCount: preUpgrade.count, newestPreUpgrade: preUpgrade.newest
        )
    }

    func unreadableEntries() -> UnreadableEntriesProbe { unreadableEntriesProvider() }

    func whisperModelFile() -> WhisperModelFileProbe {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: whisperModelPath.path)
        var size: Int64?
        if exists, let attributes = try? fm.attributesOfItem(atPath: whisperModelPath.path),
           let bytes = attributes[.size] as? NSNumber {
            size = bytes.int64Value
        }
        return WhisperModelFileProbe(modelName: whisperModelName, exists: exists, sizeBytes: size, expectedMB: whisperExpectedMB)
    }

    func whisperModelDigest() -> WhisperDigestProbe {
        guard FileManager.default.fileExists(atPath: whisperModelPath.path) else { return .unavailable }
        // Streams the file in 1 MiB chunks, so a multi-gigabyte model never sits
        // in memory (this runs off the main thread; see `DoctorView.run`).
        guard let matches = try? ModelDigest.matches(fileAt: whisperModelPath, expected: whisperExpectedSHA256) else {
            return .unavailable
        }
        return matches ? .matches : .mismatch
    }

    func toolHealthChecks() async -> [ToolHealthCheck] {
        await toolHealthProvider()
    }

    /// The `.sqlite` files in `directory` and the newest modification date.
    private static func scan(_ directories: [URL]) -> (count: Int, newest: Date?) {
        let fm = FileManager.default
        var entries: [URL] = []
        for directory in directories {
            entries += (try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        let files = entries.filter { $0.pathExtension == "sqlite" }
        let dates = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return (files.count, dates.max())
    }

    // MARK: Building the live probes from app state

    /// Whether `url` points at this Mac (`127.0.0.1`, `localhost`, `::1`). Doctor
    /// only ever contacts Ollama when it does — the privacy rule is that nothing
    /// leaves the machine.
    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host == "[::1]" || host == "127.0.0.1" || host.hasPrefix("127.")
    }

    /// The tool checks Doctor reuses from `ToolHealth`, minus the data-folder row
    /// (Doctor has its own, richer one) and with the Ollama probe held back unless
    /// its address is loopback. Never prompts: Screen Recording uses the
    /// non-authoritative preflight.
    @MainActor
    static func reusedToolHealthChecks(
        settings: AppSettings,
        integrations: Integrations,
        includeScheduling: Bool
    ) async -> [ToolHealthCheck] {
        var checks: [ToolHealthCheck] = [
            ToolHealth.microphoneCheck(),
            await ToolHealth.screenRecordingCheck(authoritative: false),
            ToolHealth.whisperModelCheck(settings: settings)
        ]
        let backend = integrations.effectiveAssistantBackend
        if backend != .appleIntelligence && !isLoopback(settings.ollamaBaseURL) {
            checks.append(ToolHealthCheck(
                kind: .ollama,
                title: "AI summaries & chat",
                status: .warning,
                detail: "Ollama's address isn't on this Mac, so Doctor didn't contact it. Aletheia is designed to talk only to Ollama running on this Mac (127.0.0.1)."
            ))
        } else {
            checks.append(await ToolHealth.assistantCheck(
                settings: settings, backend: backend, assistant: integrations.makeAssistant()))
        }
        if includeScheduling {
            checks.append(ToolHealth.calendarCheck())
            checks.append(ToolHealth.remindersCheck())
        }
        return checks
    }

    /// Live probes wired to the running app's state.
    @MainActor
    static func make(
        settings: AppSettings,
        appModel: AppModel,
        integrations: Integrations
    ) -> LiveDoctorProbes {
        let includeScheduling = appModel.featureRegistry.contains(id: EventKitSchedulingFeatureModule.id)
        let store = appModel.store
        // A locked encrypted folder makes every record look unreadable; that's the
        // lock, not damage, so don't report it as such.
        let folderLocked = appModel.isEncryptionEnabled && !appModel.isEncryptionUnlocked
        let unreadableProvider: () -> UnreadableEntriesProbe = {
            guard let store, !folderLocked else { return .notAvailable }
            return .count(store.scanForUnreadableEntries().count)
        }
        return LiveDoctorProbes(
            dataRoot: settings.dataRootURL,
            appDatabaseFailure: appModel.databaseState.failure,
            encryptionInUse: appModel.isEncryptionEnabled,
            encryptionUnlocked: appModel.isEncryptionUnlocked,
            whisperModelPath: settings.whisperModelPath,
            whisperModelName: settings.whisperModel.displayName,
            whisperExpectedMB: settings.whisperModel.approximateSizeMB,
            whisperExpectedSHA256: settings.whisperModel.expectedSHA256,
            unreadableEntriesProvider: unreadableProvider,
            toolHealthProvider: {
                await LiveDoctorProbes.reusedToolHealthChecks(
                    settings: settings, integrations: integrations, includeScheduling: includeScheduling)
            }
        )
    }
}
