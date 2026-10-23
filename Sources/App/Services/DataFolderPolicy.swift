import Foundation
import Darwin

enum DataFolderSelectionError: LocalizedError {
    case rejected(String)
    var errorDescription: String? {
        if case .rejected(let message) = self { return message }
        return nil
    }
}

enum DataFolderPolicy {
    struct ResourceFacts {
        var ubiquitous: Bool = false
        var localVolume: Bool? = nil
        var removableVolume: Bool = false
        var encryptedVolume: Bool? = nil
        /// The folder holds a sync client's marker file (Dropbox writes `.dropbox` at the root of a folder it syncs).
        var syncMarker: Bool = false
    }
    enum Verdict: Equatable {
        case ok
        case iCloudDrive
        case iCloudDesktopDocuments
        case thirdPartyCloud(String)
        case networkVolume
        case removableUnencrypted

        var explanation: String {
            switch self {
            case .ok: return "This folder is local."
            case .iCloudDrive, .iCloudDesktopDocuments: return "This folder syncs with iCloud. Choose a folder that stays on this Mac."
            case .thirdPartyCloud(let provider): return "This folder is managed by \(provider). Choose a folder that stays on this Mac."
            case .networkVolume: return "Network folders cannot hold Aletheia data. Choose a folder on this Mac."
            case .removableUnencrypted: return "This removable disk is not encrypted. Choose an encrypted local disk."
            }
        }
    }

    static var realHome: URL {
        guard let account = getpwuid(getuid()) else { return FileManager.default.homeDirectoryForCurrentUser }
        return URL(fileURLWithPath: String(cString: account.pointee.pw_dir), isDirectory: true)
    }

    static func verdict(
        for url: URL,
        realHome: URL = realHome,
        resourceValues: (URL) -> URLResourceValues? = { try? $0.resourceValues(forKeys: [
            .isUbiquitousItemKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEncryptedKey
        ]) },
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Verdict {
        verdict(for: url, realHome: realHome, facts: { candidate in
            let marker = fileExists(candidate.appendingPathComponent(".dropbox"))
            guard let values = resourceValues(candidate) else {
                return marker ? ResourceFacts(syncMarker: true) : nil
            }
            return ResourceFacts(
                ubiquitous: values.isUbiquitousItem == true,
                localVolume: values.volumeIsLocal,
                removableVolume: values.volumeIsRemovable == true,
                encryptedVolume: values.volumeIsEncrypted,
                syncMarker: marker
            )
        })
    }

    /// Sync clients that keep their folder directly in the home folder rather
    /// than under ~/Library/CloudStorage (older Dropbox, Google Drive, OneDrive and Box installs).
    static let homeSyncFolderPrefixes: [(prefix: String, provider: String)] = [
        ("dropbox", "Dropbox"),
        ("google drive", "Google Drive"),
        ("onedrive", "OneDrive"),
    ]
    /// Box uses a plain name, so only its exact folder names count.
    static let homeSyncFolderNames: [String: String] = ["box": "Box", "box sync": "Box"]

    /// Volumes that are a sync client's virtual drive (older Google Drive installs mount one).
    static let syncVolumePrefixes: [(prefix: String, provider: String)] = [
        ("/volumes/googledrive", "Google Drive"),
        ("/volumes/google drive", "Google Drive"),
    ]

    /// Whether the move-to-this-Mac sheet may show. Never above the app lock: a
    /// sheet is its own window, so the lock cover on the main window would not hide it.
    static func presentsMoveSheet(requested: Bool, appLocked: Bool) -> Bool {
        requested && !appLocked
    }

    static func verdict(for url: URL, realHome: URL, facts: (URL) -> ResourceFacts?) -> Verdict {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = realHome.standardizedFileURL.resolvingSymlinksInPath().path
        // APFS and HFS+ are case-insensitive by default, so compare paths that way.
        let lowerPath = path.lowercased()
        let lowerHome = home.lowercased()
        if contains(lowerPath, in: lowerHome + "/library/mobile documents") { return .iCloudDrive }
        let providers = lowerHome + "/library/cloudstorage"
        if contains(lowerPath, in: providers) {
            let display = path.count == lowerPath.count ? path : lowerPath
            let suffix = display.dropFirst(providers.count).split(separator: "/").first.map(String.init) ?? "a cloud provider"
            return .thirdPartyCloud(suffix)
        }
        if contains(lowerPath, in: lowerHome),
           let topLevel = lowerPath.dropFirst(lowerHome.count).split(separator: "/").first.map(String.init),
           let provider = homeSyncFolderNames[topLevel]
            ?? homeSyncFolderPrefixes.first(where: { topLevel == $0.prefix || topLevel.hasPrefix($0.prefix + " ") })?.provider {
            return .thirdPartyCloud(provider)
        }
        if let match = syncVolumePrefixes.first(where: { lowerPath.hasPrefix($0.prefix) }) {
            return .thirdPartyCloud(match.provider)
        }
        for ancestor in ancestors(of: path) {
            if let values = facts(ancestor) {
                if values.ubiquitous { return .iCloudDesktopDocuments }
                if values.syncMarker { return .thirdPartyCloud("Dropbox") }
            }
        }
        if let values = facts(URL(fileURLWithPath: path, isDirectory: true)) {
            if values.localVolume == false { return .networkVolume }
            if values.removableVolume && values.encryptedVolume != true { return .removableUnencrypted }
        }
        return .ok
    }

    /// The folder and each folder above it, ending at `/`. Built from the path's
    /// components: on macOS 15 `deletingLastPathComponent()` turns `/` into `/..`
    /// rather than stopping.
    static func ancestors(of path: String) -> [URL] {
        let components = URL(fileURLWithPath: path).pathComponents
        return (1...max(components.count, 1)).reversed().map { count in
            URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(count))), isDirectory: true)
        }
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}
