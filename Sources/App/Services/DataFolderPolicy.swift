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
        ]) }
    ) -> Verdict {
        verdict(for: url, realHome: realHome, facts: { candidate in
            guard let values = resourceValues(candidate) else { return nil }
            return ResourceFacts(
                ubiquitous: values.isUbiquitousItem == true,
                localVolume: values.volumeIsLocal,
                removableVolume: values.volumeIsRemovable == true,
                encryptedVolume: values.volumeIsEncrypted
            )
        })
    }

    static func verdict(for url: URL, realHome: URL, facts: (URL) -> ResourceFacts?) -> Verdict {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = realHome.standardizedFileURL.resolvingSymlinksInPath().path
        if contains(path, in: home + "/Library/Mobile Documents") { return .iCloudDrive }
        let providers = home + "/Library/CloudStorage"
        if contains(path, in: providers) {
            let suffix = path.dropFirst(providers.count).split(separator: "/").first.map(String.init) ?? "a cloud provider"
            return .thirdPartyCloud(suffix)
        }
        var ancestor = URL(fileURLWithPath: path, isDirectory: true)
        while true {
            if let values = facts(ancestor), values.ubiquitous {
                return .iCloudDesktopDocuments
            }
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
        if let values = facts(URL(fileURLWithPath: path, isDirectory: true)) {
            if values.localVolume == false { return .networkVolume }
            if values.removableVolume && values.encryptedVolume != true { return .removableUnencrypted }
        }
        return .ok
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}
