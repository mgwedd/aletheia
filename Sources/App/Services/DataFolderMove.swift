import Foundation
import CryptoKit

enum DataFolderMove {
    enum MoveError: LocalizedError {
        case destinationNotEmpty
        case symbolicLink
        case verificationFailed
        case overlappingFolders

        var errorDescription: String? {
            switch self {
            case .destinationNotEmpty: return "The destination data folder already contains files. Choose another local folder."
            case .symbolicLink: return "The data folder contains a symbolic link. Remove it before moving the folder."
            case .verificationFailed: return "The copied files did not verify. The original folder remains unchanged."
            case .overlappingFolders: return "Choose a destination outside the original folder."
            }
        }
    }

    /// Where a move into a folder the clinician picked puts the data: a new
    /// subfolder, so the copy is staged inside the picked folder (the only place
    /// the sandbox lets the app write) instead of next to it.
    static func destination(inChosenFolder folder: URL) -> URL {
        folder.appendingPathComponent("Aletheia Data", isDirectory: true)
    }

    static func copyAndRebind(
        source: URL,
        destination: URL,
        verify: (URL, URL) throws -> Bool = verifyCopy,
        rebind: (URL) throws -> Void
    ) throws {
        let files = FileManager.default
        let sourcePath = source.resolvingSymlinksInPath().path
        let destinationPath = destination.resolvingSymlinksInPath().path
        guard sourcePath != destinationPath,
              !sourcePath.hasPrefix(destinationPath + "/"),
              !destinationPath.hasPrefix(sourcePath + "/") else {
            throw MoveError.overlappingFolders
        }
        if files.fileExists(atPath: destination.path) {
            guard (try files.contentsOfDirectory(atPath: destination.path)).isEmpty else {
                throw MoveError.destinationNotEmpty
            }
            try files.removeItem(at: destination)
        }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".aletheia-move-\(UUID().uuidString)")
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        guard try verify(source, staging) else { throw MoveError.verificationFailed }
        try files.moveItem(at: staging, to: destination)
        do {
            try rebind(destination)
        } catch {
            try? files.removeItem(at: destination)
            throw error
        }
    }

    /// Removes the folder that was copied from, once the user chooses to.
    static func deleteOriginal(_ original: URL) throws {
        try FileManager.default.removeItem(at: original)
    }

    static func verifyCopy(_ source: URL, _ copy: URL) throws -> Bool {
        let original = try manifest(at: source)
        let duplicate = try manifest(at: copy)
        return original == duplicate && original.keys.filter { $0.hasSuffix("/patient.json") }.count == duplicate.keys.filter { $0.hasSuffix("/patient.json") }.count
    }

    static func manifest(at root: URL) throws -> [String: String] {
        let files = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = files.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: []) else {
            throw MoveError.verificationFailed
        }
        var result: [String: String] = [:]
        let rootPath = root.resolvingSymlinksInPath().path
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { throw MoveError.symbolicLink }
            let filePath = file.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(rootPath + "/") else { throw MoveError.verificationFailed }
            let relative = String(filePath.dropFirst(rootPath.count))
            if values.isDirectory == true {
                result[relative] = "directory"
            } else {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    hash.update(data: chunk)
                }
                result[relative] = hash.finalize().map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }
}
