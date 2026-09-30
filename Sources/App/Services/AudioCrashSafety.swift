import Foundation

/// Provides crash-safe continuous header flushing for recorded audio files.
///
/// When `AVAudioFile` appends audio PCM buffers to disk, the raw PCM sample bytes
/// are written, but `AVAudioFile` only updates the file header's total frame/chunk
/// size when `AVAudioFile` is closed (`file = nil`). If the process crashes or is
/// killed mid-session without closing the file, standard readers (`AVAudioFile(forReading:)`,
/// `AudioResampler`) see header size = 0 and report 0 frames of audio.
///
/// `AudioCrashSafety` inspects the file header on disk after buffer writes and
/// updates the RIFF (WAV) or CAF `data` chunk size to reflect the actual file size
/// on disk, syncing the descriptor. Even if SIGKILL or a power loss occurs mid-session,
/// the file on disk remains a fully valid, readable audio file up to the last frame.
enum AudioCrashSafety {
    /// Flushes the underlying audio file header at `url` so that even if the app
    /// crashes abruptly without closing `AVAudioFile`, the audio file on disk contains
    /// a valid, readable header length up to the last byte written.
    @discardableResult
    static func flushHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }

        do {
            let fileSize = try handle.seekToEnd()
            guard fileSize >= 44 else { return false }

            try handle.seek(toOffset: 0)
            let headerData = try handle.read(upToCount: 16384) ?? Data()
            guard headerData.count >= 12 else { return false }

            let magic = String(decoding: headerData.prefix(4), as: UTF8.self)
            if magic == "RIFF" {
                return updateWAVHeader(handle: handle, fileSize: fileSize, headerData: headerData)
            } else if magic == "caff" {
                return updateCAFHeader(handle: handle, fileSize: fileSize, headerData: headerData)
            }
            return false
        } catch {
            return false
        }
    }

    private static func updateWAVHeader(handle: FileHandle, fileSize: UInt64, headerData: Data) -> Bool {
        let riffSize = UInt32(min(fileSize - 8, UInt64(UInt32.max)))
        var riffSizeLE = riffSize.littleEndian

        do {
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: Data(bytes: &riffSizeLE, count: 4))

            var offset = 12
            while offset + 8 <= headerData.count {
                let chunkIDData = headerData[offset..<(offset + 4)]
                let chunkID = String(decoding: chunkIDData, as: UTF8.self)
                guard let chunkSize = readUInt32LE(at: offset + 4, in: headerData) else { break }

                if chunkID == "data" {
                    let dataChunkDataOffset = UInt64(offset + 8)
                    if fileSize >= dataChunkDataOffset {
                        let actualDataSize = UInt32(min(fileSize - dataChunkDataOffset, UInt64(UInt32.max)))
                        var dataSizeLE = actualDataSize.littleEndian
                        try handle.seek(toOffset: UInt64(offset + 4))
                        try handle.write(contentsOf: Data(bytes: &dataSizeLE, count: 4))
                        try handle.synchronize()
                        return true
                    }
                }
                let pad = Int(chunkSize % 2)
                let nextOffset = offset + 8 + Int(chunkSize) + pad
                if nextOffset <= offset { break }
                offset = nextOffset
            }
        } catch {
            return false
        }
        return false
    }

    private static func updateCAFHeader(handle: FileHandle, fileSize: UInt64, headerData: Data) -> Bool {
        var offset = 8
        do {
            while offset + 12 <= headerData.count {
                let chunkIDData = headerData[offset..<(offset + 4)]
                let chunkID = String(decoding: chunkIDData, as: UTF8.self)
                guard let chunkSize = readInt64BE(at: offset + 4, in: headerData) else { break }

                if chunkID == "data" {
                    let dataChunkDataOffset = UInt64(offset + 12)
                    if fileSize >= dataChunkDataOffset {
                        let actualDataSize = Int64(fileSize - dataChunkDataOffset)
                        var dataSizeBE = actualDataSize.bigEndian
                        try handle.seek(toOffset: UInt64(offset + 4))
                        try handle.write(contentsOf: Data(bytes: &dataSizeBE, count: 8))
                        try handle.synchronize()
                        return true
                    }
                }

                if chunkSize < 0 { break }
                let nextOffset = offset + 12 + Int(chunkSize)
                if nextOffset <= offset { break }
                offset = nextOffset
            }
        } catch {
            return false
        }
        return false
    }

    private static func readUInt32LE(at offset: Int, in data: Data) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) |
               (UInt32(data[offset + 1]) << 8) |
               (UInt32(data[offset + 2]) << 16) |
               (UInt32(data[offset + 3]) << 24)
    }

    private static func readInt64BE(at offset: Int, in data: Data) -> Int64? {
        guard offset + 8 <= data.count else { return nil }
        return Int64(data[offset]) << 56 |
               Int64(data[offset + 1]) << 48 |
               Int64(data[offset + 2]) << 40 |
               Int64(data[offset + 3]) << 32 |
               Int64(data[offset + 4]) << 24 |
               Int64(data[offset + 5]) << 16 |
               Int64(data[offset + 6]) << 8 |
               Int64(data[offset + 7])
    }
}
