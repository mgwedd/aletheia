import Foundation
import SQLite3

/// What a read-only look at the database file found.
struct DatabaseInspection: Equatable {
    enum Integrity: Equatable {
        /// `PRAGMA integrity_check` reported `ok`.
        case ok
        /// SQLite reported this many problems (a count only — the messages name
        /// tables and pages, which Doctor never surfaces).
        case problems(count: Int)
        /// The check couldn't run (the file wouldn't open, or was missing).
        case notRun
    }

    var fileExists: Bool
    /// `PRAGMA user_version`, when the file could be read.
    var schemaVersion: Int?
    var integrity: Integrity
    /// Why the file couldn't be read, when it couldn't.
    var failure: DatabaseOpenFailure?

    static let missing = DatabaseInspection(fileExists: false, schemaVersion: nil, integrity: .notRun, failure: nil)
}

/// Opens the database **read-only** — no create, no migrate, no writes, so it can
/// never change a therapist's data — and reports its schema version and
/// `PRAGMA integrity_check` result. Independent of the app's own open connection,
/// so Doctor can still say something useful when that connection never opened.
enum DatabaseInspector {
    /// `PRAGMA integrity_check(N)` stops after this many problems; the count is
    /// all Doctor reports.
    static let maxProblemsReported = 100

    static func inspect(databaseAt url: URL, supportedSchemaVersion: Int = SchemaMigrator.latestVersion) -> DatabaseInspection {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }

        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        defer { if let handle { sqlite3_close(handle) } }
        guard openCode == SQLITE_OK, let db = handle else {
            return DatabaseInspection(
                fileExists: true, schemaVersion: nil, integrity: .notRun,
                failure: DatabaseOpenFailure(sqliteCode: openCode)
            )
        }

        // The first real read is where "not a database" / corruption surfaces.
        var version: Int?
        var readCode: Int32 = SQLITE_OK
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) != SQLITE_OK {
            readCode = sqlite3_extended_errcode(db)
        } else if sqlite3_step(stmt) == SQLITE_ROW {
            version = Int(sqlite3_column_int(stmt, 0))
        } else {
            readCode = sqlite3_extended_errcode(db)
        }
        sqlite3_finalize(stmt)
        guard let schemaVersion = version else {
            return DatabaseInspection(
                fileExists: true, schemaVersion: nil, integrity: .notRun,
                failure: DatabaseOpenFailure(sqliteCode: readCode)
            )
        }

        let integrity = integrityCheck(db)
        var failure: DatabaseOpenFailure?
        if schemaVersion > supportedSchemaVersion {
            failure = DatabaseOpenFailure(
                kind: .schemaNewerThanApp,
                reason: "Database format v\(schemaVersion); this version of Aletheia understands up to v\(supportedSchemaVersion).",
                dataVersion: schemaVersion,
                appVersion: supportedSchemaVersion
            )
        }
        return DatabaseInspection(fileExists: true, schemaVersion: schemaVersion, integrity: integrity, failure: failure)
    }

    /// Runs `PRAGMA integrity_check` and reduces it to ok / a problem count. Only
    /// the *number* of result rows is kept; their text is never read past the
    /// single-row "ok" comparison.
    private static func integrityCheck(_ db: OpaquePointer) -> DatabaseInspection.Integrity {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check(\(maxProblemsReported));", -1, &stmt, nil) == SQLITE_OK else {
            return .problems(count: 1)
        }
        defer { sqlite3_finalize(stmt) }
        var rows = 0
        var firstRowIsOK = false
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows += 1
                if rows == 1, let text = sqlite3_column_text(stmt, 0) {
                    firstRowIsOK = String(cString: text) == "ok"
                }
            } else if rc == SQLITE_DONE {
                break
            } else {
                // An error mid-check (e.g. a page can't be read) is itself a problem.
                rows += 1
                break
            }
        }
        if rows == 1 && firstRowIsOK { return .ok }
        return .problems(count: max(rows, 1))
    }
}
