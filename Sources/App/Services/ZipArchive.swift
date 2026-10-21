import Compression
import Foundation

/// A small ZIP writer: deflate (or stored, when that is no smaller), UTF-8 names,
/// no zip64. Built on Apple's Compression framework, so there's no third-party
/// code and nothing leaves the Mac. It exists for one job, bundling a patient's
/// text files; the limits below are far above what that produces.
enum ZipArchive {
    struct Entry: Equatable {
        /// Path inside the archive, `/`-separated, relative: "Sessions/2026-09-16/Transcript.txt".
        let path: String
        let data: Data
        let modified: Date
    }

    enum Failure: Error, Equatable {
        case tooManyEntries
        case tooLarge
        case invalidPath(String)
    }

    static let maxEntries = 65_535
    /// The classic ZIP format stores sizes and offsets in 32 bits.
    static let maxBytes = 4_000_000_000

    static func data(for entries: [Entry]) throws -> Data {
        guard entries.count <= maxEntries else { throw Failure.tooManyEntries }
        var archive = Data()
        var directory = Data()
        for entry in entries {
            guard isValid(path: entry.path) else { throw Failure.invalidPath(entry.path) }
            guard entry.data.count <= maxBytes else { throw Failure.tooLarge }
            let name = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let (method, payload) = compressed(entry.data)
            let (time, date) = dosStamp(entry.modified)
            let offset = archive.count
            guard offset + 30 + name.count + payload.count < maxBytes else { throw Failure.tooLarge }

            archive.appendLE32(0x0403_4B50)
            archive.appendLE16(20)
            archive.appendLE16(utf8NameFlag)
            archive.appendLE16(method)
            archive.appendLE16(time)
            archive.appendLE16(date)
            archive.appendLE32(crc)
            archive.appendLE32(UInt32(payload.count))
            archive.appendLE32(UInt32(entry.data.count))
            archive.appendLE16(UInt16(name.count))
            archive.appendLE16(0)
            archive.append(name)
            archive.append(payload)

            directory.appendLE32(0x0201_4B50)
            directory.appendLE16(20)
            directory.appendLE16(20)
            directory.appendLE16(utf8NameFlag)
            directory.appendLE16(method)
            directory.appendLE16(time)
            directory.appendLE16(date)
            directory.appendLE32(crc)
            directory.appendLE32(UInt32(payload.count))
            directory.appendLE32(UInt32(entry.data.count))
            directory.appendLE16(UInt16(name.count))
            directory.appendLE16(0)
            directory.appendLE16(0)
            directory.appendLE16(0)
            directory.appendLE16(0)
            directory.appendLE32(0)
            directory.appendLE32(UInt32(offset))
            directory.append(name)
        }
        guard archive.count + directory.count + 22 < maxBytes else { throw Failure.tooLarge }
        let directoryOffset = archive.count
        archive.append(directory)
        archive.appendLE32(0x0605_4B50)
        archive.appendLE16(0)
        archive.appendLE16(0)
        archive.appendLE16(UInt16(entries.count))
        archive.appendLE16(UInt16(entries.count))
        archive.appendLE32(UInt32(directory.count))
        archive.appendLE32(UInt32(directoryOffset))
        archive.appendLE16(0)
        return archive
    }

    /// CRC-32 (the zip / PNG polynomial).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for byte in bytes {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return ~crc
    }

    /// Relative, `/`-separated, no `..`, no backslashes, short enough for any filesystem.
    static func isValid(path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 255, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == ".." || $0 == "." }
    }

    // MARK: - Pieces

    private static let utf8NameFlag: UInt16 = 0x0800

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    /// Method 8 (deflate) when it makes the data smaller, otherwise method 0 (stored).
    /// Apple's `COMPRESSION_ZLIB` is a raw deflate stream, which is what ZIP holds.
    private static func compressed(_ data: Data) -> (method: UInt16, payload: Data) {
        guard !data.isEmpty else { return (0, data) }
        let capacity = data.count + data.count / 16 + 1024
        var buffer = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&buffer, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0, written < data.count else { return (0, data) }
        return (8, Data(buffer[0..<written]))
    }

    /// MS-DOS time and date, in local time, clamped to the format's 1980...2107 range.
    private static func dosStamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = min(max(parts.year ?? 1980, 1980), 2107)
        let month: Int = parts.month ?? 1
        let day: Int = parts.day ?? 1
        let hour: Int = parts.hour ?? 0
        let minute: Int = parts.minute ?? 0
        let halfSeconds: Int = (parts.second ?? 0) / 2
        // Split into typed steps: one long chain of shifts and ORs times out the type checker.
        let datePart: Int = ((year - 1980) << 9) | (month << 5) | day
        let timePart: Int = (hour << 11) | (minute << 5) | halfSeconds
        return (UInt16(timePart), UInt16(datePart))
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE32(_ value: UInt32) {
        appendLE16(UInt16(truncatingIfNeeded: value))
        appendLE16(UInt16(truncatingIfNeeded: value >> 16))
    }
}
