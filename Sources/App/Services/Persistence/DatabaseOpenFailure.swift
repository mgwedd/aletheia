import Foundation
import SQLite3

/// Why the SQLite database could not be opened — a typed outcome instead of a
/// silent `nil`, so the app can tell the therapist *what* is wrong and what to
/// do about it (see `DatabaseFailureGuidance`) rather than carrying on while
/// notes and chat quietly fail to save.
///
/// ```
///   SQLitePersistenceCore(opening:)  ──throws──▶  DatabaseOpenFailure
///        │                                            │  .kind    → which steps to show
///        ▼                                            │  .reason  → PHI-free detail
///   CommentStore(opening:)                            ▼
///        │                                     AppModel.databaseState
///        ▼                                     = .unavailable(failure)
///   AppModel.commentStore                             │
///                                                     ▼
///                                        banner in the main window + Doctor
/// ```
///
/// `reason` is built only from SQLite's static result-code text (`sqlite3_errstr`)
/// and schema version numbers — never from row contents, SQL text or file names —
/// so it is safe to show on screen and to include in a copied Doctor report.
struct DatabaseOpenFailure: Error, Equatable {
    enum Kind: String, Equatable, CaseIterable {
        /// The file couldn't be opened at all: missing or unreadable folder,
        /// permissions, a read-only or unmounted volume.
        case cannotOpen
        /// The file is busy/locked by another process, the disk is full, or the
        /// disk reported an I/O error.
        case lockedOrDiskFull
        /// The database was written by a newer Aletheia than this one; this build
        /// declines to open (and so never rewrites) it.
        case schemaNewerThanApp
        /// A schema upgrade was needed but the pre-upgrade safety snapshot could
        /// not be written, so the upgrade was refused and the data left untouched.
        case migrationRefused
        /// The schema upgrade itself failed (and was rolled back).
        case migrationFailed
        /// The file isn't a valid SQLite database or its pages are damaged.
        case corrupt
        case unknown
    }

    let kind: Kind
    /// PHI-free, human-readable detail (SQLite result-code text and/or versions).
    let reason: String
    /// The SQLite result code behind the failure, when there was one.
    let sqliteCode: Int32?
    /// For `.schemaNewerThanApp` / migration failures: the schema versions involved.
    let dataVersion: Int?
    let appVersion: Int?

    init(kind: Kind, reason: String, sqliteCode: Int32? = nil, dataVersion: Int? = nil, appVersion: Int? = nil) {
        self.kind = kind
        self.reason = reason
        self.sqliteCode = sqliteCode
        self.dataVersion = dataVersion
        self.appVersion = appVersion
    }

    /// A failure classified straight from a SQLite result code (primary or
    /// extended).
    init(sqliteCode code: Int32) {
        self.init(
            kind: Self.classify(sqliteCode: code),
            reason: Self.describe(sqliteCode: code),
            sqliteCode: code
        )
    }

    /// Pure mapping from a SQLite result code to a failure kind. Extended codes
    /// carry the primary code in their low byte, so it's masked first.
    static func classify(sqliteCode code: Int32) -> Kind {
        switch code & 0xFF {
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return .corrupt
        case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_FULL, SQLITE_IOERR:
            return .lockedOrDiskFull
        case SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_READONLY, SQLITE_AUTH:
            return .cannotOpen
        default:
            return .unknown
        }
    }

    /// SQLite's own static description of a result code, e.g. "database disk
    /// image is malformed". Never contains file names or row data.
    static func describe(sqliteCode code: Int32) -> String {
        let raw: UnsafePointer<CChar>? = sqlite3_errstr(code)
        let text = raw.map { String(cString: $0) } ?? "unknown error"
        return "SQLite error \(code): \(text)"
    }
}

/// Whether the app's database is usable right now. `AppModel` publishes this so
/// the UI can show an unmissable error state instead of silently dropping writes.
enum DatabaseState: Equatable {
    /// No data folder chosen yet (first run) — nothing to open.
    case noDataFolder
    /// Opened (and migrated, if needed) successfully.
    case available
    /// Could not be opened; notes and chat cannot be saved until this is fixed.
    case unavailable(DatabaseOpenFailure)

    var failure: DatabaseOpenFailure? {
        if case .unavailable(let failure) = self { return failure }
        return nil
    }
}

/// A save that did not reach the database. Thrown by the chat-save paths in
/// `Store` (which used to discard the failure) so callers can surface it.
enum DatabaseWriteError: LocalizedError, Equatable {
    /// The database never opened (see `DatabaseState.unavailable`).
    case databaseUnavailable
    /// The database is open but the write was rejected (disk full, locked, …).
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return "Aletheia's database isn't available, so this couldn't be saved."
        case .writeFailed:
            return "The database rejected the write — the disk may be full or the file locked."
        }
    }
}
