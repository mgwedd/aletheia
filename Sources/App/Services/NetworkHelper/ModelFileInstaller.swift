import Foundation

/// Puts a finished download in place: verified against its pinned digest first,
/// and only then swapped in for any existing file.
enum ModelFileInstaller {
    /// Moves the finished download to `<destination>.partial`, verifies it there,
    /// and only then replaces `destination`. Any failure deletes the partial and
    /// leaves an existing good file untouched; an unverified file is never at
    /// the final path.
    static func installVerified(from location: URL, to destination: URL, expectedSHA256: String) throws {
        let fm = FileManager.default
        let partial = partialURL(for: destination)
        try? fm.removeItem(at: partial)
        try fm.moveItem(at: location, to: partial)
        do {
            try ModelDigest.verify(fileAt: partial, expectedSHA256: expectedSHA256)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: destination)
            }
            try? fm.removeItem(at: legacyResumeDataURL(for: destination))
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    static func partialURL(for destination: URL) -> URL {
        destination.appendingPathExtension("partial")
    }

    /// Where earlier versions kept URLSession resume data. Nothing writes it
    /// now; it is only cleaned up.
    static func legacyResumeDataURL(for destination: URL) -> URL {
        destination.appendingPathExtension("resume")
    }
}
