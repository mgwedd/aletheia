import CryptoKit
import Foundation

/// An **end-to-end-encrypted backup of a whole data folder**: every file under
/// the folder (the database snapshot, notes, transcripts, audio, the audit
/// ledger, the key wrapper) packed into one container and sealed with
/// `ChunkedCipher` (AES-256-GCM, every chunk authenticated). A wrong key, a
/// flipped bit, a dropped or reordered chunk all fail before a single file is
/// written, and each file's SHA-256 is checked again on the way out.
///
/// Container layout (the plaintext inside the sealed envelope):
///
///   "ALFB" ‖ version(1) ‖ file bytes, back to back ‖ manifest JSON ‖ manifestLength(8, BE)
///
/// Restoring never writes into an existing folder: files are extracted into a
/// private staging folder next to the destination and moved into place only
/// when the destination is missing or empty.
enum FolderBackupArchive {
    static let magic = Data("ALFB".utf8)
    static let version: UInt8 = 1
    /// The database inside the archive is always stored under this name.
    static let databaseName = "Aletheia.sqlite"

    /// Names (relative to the folder root) that are not archived: the backups
    /// folder itself, the live database files (a consistent snapshot is stored
    /// instead) and the search index (rebuilt from the data on open).
    static let excludedTopLevel: Set<String> = [
        BackupLayout.rootName,
        databaseName, databaseName + "-wal", databaseName + "-shm", databaseName + "-journal",
        "search.sqlite", "search.sqlite-wal", "search.sqlite-shm"
    ]

    private static let manifestLimit: UInt64 = 64 << 20

    struct Entry: Codable, Equatable {
        let path: String
        let size: UInt64
        let sha256: String
    }

    struct Manifest: Codable, Equatable {
        let version: Int
        let files: [Entry]
    }

    enum RestoreError: LocalizedError, Equatable {
        case notAnArchive
        case damaged
        case destinationNotEmpty
        case sourceMissing

        var errorDescription: String? {
            switch self {
            case .notAnArchive: return "That file isn't an Aletheia encrypted backup."
            case .damaged: return "This backup is damaged or has been altered, so it was not restored."
            case .destinationNotEmpty: return "That folder already has files in it. Choose an empty folder; a restore never overwrites existing data."
            case .sourceMissing: return "The backup file wasn't found."
            }
        }
    }

    // MARK: - Create

    /// Packs `folder` (with `databaseSnapshot` standing in for the live database)
    /// into an encrypted archive at `destination`.
    static func create(folder: URL, databaseSnapshot: URL?, to destination: URL, using key: SymmetricKey) throws {
        let fm = FileManager.default
        let container = try PrivateStaging.scratchFile(prefix: "folder-backup", ext: "container")
        let sealed = try PrivateStaging.scratchFile(prefix: "folder-backup", ext: EncryptedBackupArchive.fileExtension)
        defer { PrivateStaging.remove(container) }
        do {
            var sources: [(path: String, url: URL)] = []
            for (path, url) in try listFiles(in: folder) { sources.append((path, url)) }
            if let databaseSnapshot { sources.append((databaseName, databaseSnapshot)) }
            sources.sort { $0.path < $1.path }

            let output = try FileHandle(forWritingTo: container)
            var entries: [Entry] = []
            do {
                try output.write(contentsOf: magic + Data([version]))
                for source in sources { entries.append(try append(source.url, as: source.path, to: output)) }
                let manifest = try JSONEncoder().encode(Manifest(version: Int(version), files: entries))
                try output.write(contentsOf: manifest)
                try output.write(contentsOf: UInt64(manifest.count).bigEndianData)
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
            try ChunkedCipher.seal(fileAt: container, to: sealed, using: key)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: sealed)
            } else {
                try fm.moveItem(at: sealed, to: destination)
            }
        } catch {
            PrivateStaging.remove(sealed)
            throw error
        }
    }

    // MARK: - Restore

    /// Opens `archive` with `key` and writes its files into `destination`, which
    /// must not exist or must be an empty folder. Throws without leaving partial
    /// output if the key is wrong or the archive is not intact.
    static func restore(archive: URL, to destination: URL, using key: SymmetricKey) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: archive.path) else { throw RestoreError.sourceMissing }
        guard ChunkedCipher.isEnvelope(fileAt: archive) else { throw RestoreError.notAnArchive }
        try requireEmpty(destination)

        let container = try PrivateStaging.scratchFile(prefix: "folder-restore", ext: "container")
        defer { PrivateStaging.remove(container) }
        do {
            try ChunkedCipher.open(fileAt: archive, to: container, using: key)
        } catch {
            throw RestoreError.damaged
        }

        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".aletheia-restore-\(UUID().uuidString)", isDirectory: true)
        try PrivateStaging.ensurePrivateDirectory(staging)
        do {
            if try isLegacyDatabase(container) {
                try fm.copyItem(at: container, to: staging.appendingPathComponent(databaseName))
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.appendingPathComponent(databaseName).path)
            } else {
                try extract(container: container, into: staging)
            }
            // Re-check just before placing: never replace anything that appeared.
            try requireEmpty(destination)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Helpers

    /// A destination is usable when it doesn't exist or is an empty folder.
    static func requireEmpty(_ destination: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue,
              (try? FileManager.default.contentsOfDirectory(atPath: destination.path))?.isEmpty == true
        else { throw RestoreError.destinationNotEmpty }
    }

    /// Regular files under `folder`, relative paths, without excluded names or links.
    private static func listFiles(in folder: URL) throws -> [(String, URL)] {
        let fm = FileManager.default
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return []
        }
        var result: [(String, URL)] = []
        for case let url as URL in walker {
            let relative = String(url.path.dropFirst(base.path.count + 1))
            let top = relative.split(separator: "/").first.map(String.init) ?? relative
            if excludedTopLevel.contains(top) {
                walker.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            result.append((relative, url))
        }
        return result
    }

    private static func append(_ source: URL, as path: String, to output: FileHandle) throws -> Entry {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var hasher = SHA256()
        var total: UInt64 = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += UInt64(chunk.count)
            try output.write(contentsOf: chunk)
        }
        return Entry(path: path, size: total, sha256: hex(hasher.finalize()))
    }

    private static func isLegacyDatabase(_ container: URL) throws -> Bool {
        let input = try FileHandle(forReadingFrom: container)
        defer { try? input.close() }
        let head = try input.read(upToCount: 16) ?? Data()
        return head == Data("SQLite format 3\0".utf8)
    }

    private static func extract(container: URL, into staging: URL) throws {
        let fm = FileManager.default
        let input = try FileHandle(forReadingFrom: container)
        defer { try? input.close() }
        let total = UInt64(((try fm.attributesOfItem(atPath: container.path))[.size] as? Int) ?? 0)
        let headerSize = UInt64(magic.count + 1)
        guard total >= headerSize + 8 else { throw RestoreError.damaged }

        guard try input.read(upToCount: Int(headerSize)) == magic + Data([version]) else { throw RestoreError.damaged }
        try input.seek(toOffset: total - 8)
        guard let lengthBytes = try input.read(upToCount: 8), lengthBytes.count == 8 else { throw RestoreError.damaged }
        let manifestLength = lengthBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard manifestLength <= manifestLimit, manifestLength <= total - headerSize - 8 else { throw RestoreError.damaged }
        let manifestStart = total - 8 - manifestLength
        try input.seek(toOffset: manifestStart)
        guard let manifestData = try input.read(upToCount: Int(manifestLength)), manifestData.count == Int(manifestLength),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              manifest.version == Int(version)
        else { throw RestoreError.damaged }

        var seen = Set<String>()
        var expected = headerSize
        for entry in manifest.files {
            guard isSafe(entry.path), seen.insert(entry.path).inserted else { throw RestoreError.damaged }
            let (next, overflow) = expected.addingReportingOverflow(entry.size)
            guard !overflow, next <= manifestStart else { throw RestoreError.damaged }
            expected = next
        }
        guard expected == manifestStart else { throw RestoreError.damaged }

        try input.seek(toOffset: headerSize)
        for entry in manifest.files {
            let target = staging.appendingPathComponent(entry.path)
            try PrivateStaging.ensurePrivateDirectory(target.deletingLastPathComponent())
            guard fm.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            var hasher = SHA256()
            var remaining = entry.size
            while remaining > 0 {
                let want = Int(min(remaining, 1 << 20))
                guard let chunk = try input.read(upToCount: want), chunk.count == want else { throw RestoreError.damaged }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                remaining -= UInt64(want)
            }
            guard hex(hasher.finalize()) == entry.sha256 else { throw RestoreError.damaged }
        }
    }

    /// A relative path with no empty, `.` or `..` parts and no leading slash.
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension UInt64 {
    var bigEndianData: Data { Data((0..<8).reversed().map { UInt8((self >> (UInt64($0) * 8)) & 0xFF) }) }
}
