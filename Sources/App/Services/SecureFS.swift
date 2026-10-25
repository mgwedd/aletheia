import Foundation

/// Owner-only file access for everything the app keeps in the data folder.
///
/// Directories are created 0700 and files 0600 regardless of the process umask,
/// and an existing item that is wider is tightened when it is opened or
/// rewritten. File writes are atomic: the bytes go to a sibling temp file that
/// is created 0600 (never wider, at any moment) and is renamed over the target.
enum SecureFS {
    static let directoryMode: mode_t = 0o700
    static let fileMode: mode_t = 0o600

    /// Creates `url` (and any missing parents) as 0700 and tightens `url` itself
    /// to 0700 if it already existed wider. Parents that already existed, which
    /// may be a folder the user picked, are left as they are.
    static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: Int(directoryMode)])
        // Best effort: a volume without POSIX modes (some external drives)
        // refuses chmod, and there is nothing to narrow there.
        try? tighten(url, mode: directoryMode)
    }

    /// Writes `data` to `url` atomically with mode 0600.
    static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, fileMode)
        guard fd >= 0 else { throw posixError() }
        do {
            // The umask can only narrow the mode `open` was given; pin it anyway.
            _ = fchmod(fd, fileMode)
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw posixError()
                    }
                    offset += written
                }
            }
            guard fsync(fd) == 0 else { throw posixError() }
        } catch {
            close(fd)
            unlink(temp.path)
            throw error
        }
        guard close(fd) == 0 else {
            let error = posixError()
            unlink(temp.path)
            throw error
        }
        guard rename(temp.path, url.path) == 0 else {
            let error = posixError()
            unlink(temp.path)
            throw error
        }
        // Make the rename itself durable.
        let dirFD = open(url.deletingLastPathComponent().path, O_RDONLY)
        if dirFD >= 0 { fsync(dirFD); close(dirFD) }
    }

    /// Narrows an existing file to 0600. Does nothing if `url` is absent.
    static func tightenFile(at url: URL) throws {
        try tighten(url, mode: fileMode)
    }

    private static func tighten(_ url: URL, mode: mode_t) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw posixError()
        }
        // Never follow a symlink to change the mode of something else.
        guard (info.st_mode & S_IFMT) != S_IFLNK else { return }
        let wanted = info.st_mode & 0o7777 & mode
        guard wanted != info.st_mode & 0o7777 else { return }
        guard chmod(url.path, wanted) == 0 else { throw posixError() }
    }

    private static func posixError() -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
