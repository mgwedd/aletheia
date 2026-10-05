import Foundation

/// A visible, append-only receipt of legal acceptances, written into the user's
/// own data folder as `legal-acceptance.log`.
///
/// What it is, honestly: a good-faith local record. It is **not** tamper-proof
/// and does **not** identify who was at the keyboard — no local store can prove
/// either. Its value is that it's human-readable (open it in any text editor),
/// durable (survives the UserDefaults gate being cleared), and portable (travels
/// with a backup of the data folder). Like everything else, it never leaves the
/// Mac.
///
/// The `UserDefaults` record in `AppSettings` remains the gate; this file is the
/// paper trail beside it. Writing here is best-effort: if the folder is
/// read-only, the user is never blocked — they simply have no file receipt that
/// time.
enum LegalReceipt {
    static let fileName = "legal-acceptance.log"

    /// One acceptance, as written to a single JSON line.
    struct Entry: Codable, Equatable {
        let acceptedVersion: String
        let acceptedAt: String   // ISO 8601, UTC
        let appVersion: String
    }

    /// Append one acceptance line to `<root>/legal-acceptance.log`. No-op if
    /// there's no data folder yet. Never throws — a write failure just means no
    /// file receipt this time (the UserDefaults record still stands).
    static func append(version: String, at date: Date, root: URL?, appVersion: String) {
        guard let root else { return }
        let entry = Entry(
            acceptedVersion: version,
            acceptedAt: Self.isoFormatter.string(from: date),
            appVersion: appVersion
        )
        guard let line = encodeLine(entry) else { return }
        write(line, to: root.appendingPathComponent(fileName))
    }

    /// Encodes an entry to a single newline-terminated JSON line. Exposed for
    /// tests; keeps keys on one line so the log stays grep-friendly.
    static func encodeLine(_ entry: Entry) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(entry) else { return nil }
        return json + Data("\n".utf8)
    }

    private static func write(_ data: Data, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // No file yet (or it couldn't be opened): create it with this line.
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
