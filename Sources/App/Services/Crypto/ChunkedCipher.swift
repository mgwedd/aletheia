import CryptoKit
import Foundation

/// Streaming AES-256-GCM for large files — the session audio (`mic.caf` /
/// `call.caf`), which can run to hundreds of megabytes an hour. `DataCipher`
/// seals a blob in one shot, holding the whole thing in memory; this seals a
/// file chunk by chunk so peak memory is one chunk, not the whole recording.
///
///   ┌────────┬─────────┬───────────┬────────────┬─ per chunk ───────────────┐
///   │ "ALTC" │ version │ chunkSize │ chunkCount │ len(4) ‖ GCM combined box  │ …
///   │ 4 B    │ 1 B     │ 4 B (BE)  │ 8 B (BE)   │        (repeats)           │
///   └────────┴─────────┴───────────┴────────────┴────────────────────────────┘
///
/// Each chunk is sealed independently with its own random nonce, and the fixed
/// header plus the chunk's index are fed in as GCM **additional authenticated
/// data**. That binds every chunk to its position and to the declared
/// `chunkCount`, so a reordered, duplicated, dropped, or truncated file fails to
/// open rather than silently decrypting to a shorter/scrambled recording.
enum ChunkedCipher {
    static let magic = Data("ALTC".utf8)
    static let version: UInt8 = 1
    static let defaultChunkSize = 1 << 20 // 1 MiB

    private static var headerCount: Int { magic.count + 1 + 4 + 8 }

    enum ChunkedError: LocalizedError, Equatable {
        case notAnEnvelope
        case unsupportedVersion(UInt8)
        case truncated

        var errorDescription: String? {
            switch self {
            case .notAnEnvelope: return "This file isn't an Aletheia encrypted recording."
            case let .unsupportedVersion(v): return "This recording uses a newer encryption format (v\(v)). Please update Aletheia."
            case .truncated: return "This encrypted recording is incomplete or damaged."
            }
        }
    }

    /// Whether the file at `url` begins with the chunked magic.
    static func isEnvelope(fileAt url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: magic.count)) ?? Data()
        return head == magic
    }

    /// Seals `src` into `dst`, reading and encrypting one chunk at a time.
    static func seal(fileAt src: URL, to dst: URL, using key: SymmetricKey, chunkSize: Int = defaultChunkSize) throws {
        let fileSize = ((try FileManager.default.attributesOfItem(atPath: src.path))[.size] as? Int) ?? 0
        let chunkCount = fileSize == 0 ? 0 : (fileSize + chunkSize - 1) / chunkSize

        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }

        var header = Data()
        header.append(magic)
        header.append(version)
        header.appendBigEndian(UInt32(chunkSize))
        header.appendBigEndian(UInt64(chunkCount))
        try output.write(contentsOf: header)

        var index: UInt64 = 0
        while true {
            let chunk = readFully(input, chunkSize)
            if chunk.isEmpty { break }
            let box = try AES.GCM.seal(chunk, using: key, authenticating: header + index.bigEndianBytes)
            guard let combined = box.combined else { throw ChunkedError.truncated }
            var framed = Data()
            framed.appendBigEndian(UInt32(combined.count))
            framed.append(combined)
            try output.write(contentsOf: framed)
            index += 1
            if chunk.count < chunkSize { break } // reached EOF
        }
    }

    /// Opens a file produced by `seal` into `dst`. Throws on a wrong key, a
    /// tampered/reordered/truncated file, an unknown version, or a non-envelope.
    static func open(fileAt src: URL, to dst: URL, using key: SymmetricKey) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }

        let header = readFully(input, headerCount)
        guard header.count == headerCount, header.prefix(magic.count) == magic else {
            throw header.prefix(magic.count) == magic ? ChunkedError.truncated : ChunkedError.notAnEnvelope
        }
        let version = header[header.startIndex + magic.count]
        guard version == Self.version else { throw ChunkedError.unsupportedVersion(version) }
        let chunkCount = header.readBigEndianUInt64(at: magic.count + 1 + 4)

        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }

        for index in 0..<chunkCount {
            let lenData = readFully(input, 4)
            guard lenData.count == 4 else { throw ChunkedError.truncated }
            let len = Int(lenData.readBigEndianUInt32(at: 0))
            let combined = readFully(input, len)
            guard combined.count == len else { throw ChunkedError.truncated }
            let box = try AES.GCM.SealedBox(combined: combined)
            let opened = try AES.GCM.open(box, using: key, authenticating: header + index.bigEndianBytes)
            try output.write(contentsOf: opened)
        }
    }

    /// Reads exactly `count` bytes, looping until satisfied or EOF (a single
    /// `read(upToCount:)` may return fewer). Returns fewer than `count` only at
    /// end of file.
    private static func readFully(_ handle: FileHandle, _ count: Int) -> Data {
        var buffer = Data()
        while buffer.count < count {
            guard let next = try? handle.read(upToCount: count - buffer.count), !next.isEmpty else { break }
            buffer.append(next)
        }
        return buffer
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) { append(contentsOf: value.bigEndianBytes) }
    mutating func appendBigEndian(_ value: UInt64) { append(contentsOf: value.bigEndianBytes) }

    /// Reads a big-endian UInt32 at `offset` (relative to `startIndex`).
    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return (0..<4).reduce(UInt32(0)) { acc, i in (acc << 8) | UInt32(self[start + i]) }
    }

    /// Reads a big-endian UInt64 at `offset` (relative to `startIndex`).
    func readBigEndianUInt64(at offset: Int) -> UInt64 {
        let start = startIndex + offset
        return (0..<8).reduce(UInt64(0)) { acc, i in (acc << 8) | UInt64(self[start + i]) }
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] { (0..<4).reversed().map { UInt8((self >> ($0 * 8)) & 0xFF) } }
}

private extension UInt64 {
    var bigEndianBytes: [UInt8] { (0..<8).reversed().map { UInt8((self >> (UInt64($0) * 8)) & 0xFF) } }
}
