import Foundation

/// Ordered, versioned schema migrations for the SQLite persistence core.
///
/// The database's own `PRAGMA user_version` is the schema version. On open the
/// core reads it and asks this type what to do:
///
/// ```
/// current  <  latest  → run the pending steps, in order, in one transaction,
///                       then stamp user_version = latest        (.migrate)
/// current  == latest  → nothing to do                           (.upToDate)
/// current  >  latest  → the file was written by a newer app; refuse rather
///                       than risk rewriting it with an older schema
///                                                               (.needsNewerApp)
/// ```
///
/// Each step is an idempotent SQL string applied exactly once as the schema
/// moves `n → n+1`. Step 1 is the baseline schema itself, so a brand-new
/// database and a pre-`user_version` database (which already carries the
/// baseline tables but has `user_version` 0) both converge on the same
/// versioned state: step 1's `CREATE … IF NOT EXISTS` is a no-op on the existing
/// tables, then the version is stamped.
///
/// This mirrors, at the DB level, what `SchemaCompatibility`/`StoreMetadata`
/// already do for the file-level data-folder stamp (`DataSchema`): forward
/// migrations that re-stamp, and a clean refusal of a newer version rather than
/// a silent downgrade.
///
/// The decision and ordering are pure and free of SQLite, so they're unit-tested
/// in isolation; the core supplies the actual statement executor.
enum SchemaMigrator {
    /// One ordered migration step.
    struct Migration: Equatable {
        /// The schema version this step brings the database *to* (1-based, gapless).
        let version: Int
        /// The SQL statement(s) applied together as this step. Written to be
        /// idempotent (`CREATE … IF NOT EXISTS`, etc.) so re-running the baseline
        /// on an already-populated legacy database is safe.
        let sql: String
    }

    /// The ordered migration steps. **Append** a new step for every schema change
    /// (its `version` is the previous latest + 1); never edit or reorder a step
    /// that has shipped, or existing databases will diverge.
    static let migrations: [Migration] = [
        Migration(version: 1, sql: """
        CREATE TABLE IF NOT EXISTS records (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            owner_id TEXT,
            item_id TEXT,
            payload BLOB NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (kind, id)
        );
        CREATE INDEX IF NOT EXISTS idx_records_kind_item ON records(kind, item_id);
        CREATE INDEX IF NOT EXISTS idx_records_kind_owner ON records(kind, owner_id);
        """)
    ]

    /// The newest schema version this build understands.
    static var latestVersion: Int { migrations.map(\.version).max() ?? 0 }

    /// What opening a database at `current` should do.
    enum Plan: Equatable {
        case upToDate
        case migrate(steps: [Migration], to: Int)
        case needsNewerApp(dataVersion: Int, appVersion: Int)
    }

    /// Decide what to do for a database currently at `current`, given the
    /// available `migrations` (defaults to the shipped list). Pure — no I/O.
    ///
    /// Returned steps are exactly the pending ones (`version > current`), in
    /// ascending order, regardless of how `migrations` is arranged.
    static func plan(current: Int, migrations: [Migration] = SchemaMigrator.migrations) -> Plan {
        let latest = migrations.map(\.version).max() ?? 0
        if current > latest {
            return .needsNewerApp(dataVersion: current, appVersion: latest)
        }
        if current == latest {
            return .upToDate
        }
        let steps = migrations
            .filter { $0.version > current }
            .sorted { $0.version < $1.version }
        return .migrate(steps: steps, to: latest)
    }
}
