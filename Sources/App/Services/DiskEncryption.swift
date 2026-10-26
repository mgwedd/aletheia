import DiskArbitration
import Foundation

/// Reads whether the volume holding the data folder is encrypted. Behind a
/// protocol so tests inject a fake.
protocol DiskEncryptionProbing {
    /// True/false when macOS reports the volume's encryption state; nil when it
    /// can't be read.
    func isDataVolumeEncrypted(_ url: URL) -> Bool?
}

/// The one system read the probe depends on, split out so tests can fake it.
protocol VolumeResourceProviding {
    func volumeIsEncrypted(at url: URL) -> Bool?
}

/// Reads the encryption state of the volume that really holds `url`.
///
/// `URLResourceKey.volumeIsEncryptedKey` is not used for a negative answer: on a
/// Mac with FileVault on it reports false for the Data volume and for every
/// path under it. The authoritative flag is Disk Arbitration's
/// `DAMediaEncrypted`, read for the volume `statfs` names. `statfs` follows
/// firmlinks, so `~` resolves to the Data volume rather than the sealed,
/// never-encrypted system volume that `/` and the volume URL point at. Both
/// reads are in-process and work under the App Sandbox; when Disk Arbitration
/// can't answer the result is nil (unknown), never a guessed false.
struct SystemVolumeResources: VolumeResourceProviding {
    func volumeIsEncrypted(at url: URL) -> Bool? {
        if let values = try? url.resourceValues(forKeys: [.volumeIsEncryptedKey]),
           values.volumeIsEncrypted == true {
            return true
        }
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        let device = withUnsafePointer(to: &info.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = device.withCString({ DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        return Self.isEncrypted(diskDescription: description)
    }

    /// The `DAMediaEncrypted` flag of a Disk Arbitration description; nil when absent.
    static func isEncrypted(diskDescription: [String: Any]) -> Bool? {
        diskDescription[kDADiskDescriptionMediaEncryptedKey as String] as? Bool
    }
}

struct DiskEncryptionProbe: DiskEncryptionProbing {
    var resources: VolumeResourceProviding = SystemVolumeResources()

    func isDataVolumeEncrypted(_ url: URL) -> Bool? {
        resources.volumeIsEncrypted(at: url)
    }
}

/// Whether new patient information may be entered, given the disk state.
/// Pure. Only a disk known to be unencrypted blocks; an unknown state allows
/// entry (with a warning) so nobody is locked out by a failed read. Reading and
/// exporting existing data is never gated.
enum PHIEntryGate {
    static func allowsNewPHI(diskEncrypted: Bool?) -> Bool {
        diskEncrypted != false
    }

    /// True when entry is allowed but the disk state couldn't be confirmed.
    static func warnsUnknown(diskEncrypted: Bool?) -> Bool {
        diskEncrypted == nil
    }

    static let blockedTitle = "Turn on FileVault"
    static let blockedMessage = "The disk holding your data folder isn't encrypted, so Aletheia can't add new patients, sessions or recordings yet. Turn on FileVault in System Settings, or, if the data folder is on an external drive, encrypt that drive or move the folder to this Mac. Your existing records stay readable and can be exported."
    static let unknownTitle = "Couldn't confirm disk encryption"
    static let unknownMessage = "Aletheia couldn't tell whether the disk holding your data folder is encrypted. You can continue, but check that FileVault is on in System Settings."
}
