import AVFoundation
import Foundation
import os

/// Pure level math for the live input meters on the recording panel. Nothing
/// here touches what is recorded: the recorders call it on the buffers they are
/// already handed, and the result only drives the UI.
enum AudioLevel {
    /// The quietest level the meter shows. Anything at or below this reads 0.
    static let floorDB: Float = -60

    /// Root-mean-square of `samples`; 0 for an empty buffer. Accumulates in
    /// Double so a long buffer of small values doesn't lose precision.
    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return Float((sumOfSquares(samples) / Double(samples.count)).squareRoot())
    }

    /// Maps a linear RMS (0...1 full scale) onto a 0...1 meter position:
    /// `floorDB` (-60 dBFS) is 0, 0 dBFS is 1, clamped at both ends.
    static func normalized(rms: Float) -> Float {
        guard !rms.isNaN, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - floorDB) / -floorDB))
    }

    /// Meter position (0...1) for an audio buffer, or nil when the buffer isn't
    /// 32-bit float PCM (so a format we can't read is skipped rather than
    /// misread). Channels are combined by mean power.
    static func level(of buffer: AVAudioPCMBuffer) -> Float? {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return 0 }

        var total = 0.0
        var count = 0
        if buffer.format.isInterleaved {
            // One pointer to frames * channelCount interleaved samples.
            let n = frames * channelCount
            total = sumOfSquares(UnsafeBufferPointer(start: channels[0], count: n))
            count = n
        } else {
            for channel in 0..<channelCount {
                total += sumOfSquares(UnsafeBufferPointer(start: channels[channel], count: frames))
            }
            count = frames * channelCount
        }
        let rms = Float((total / Double(count)).squareRoot())
        return normalized(rms: rms)
    }

    private static func sumOfSquares(_ samples: UnsafeBufferPointer<Float>) -> Double {
        var sum = 0.0
        for sample in samples {
            sum += Double(sample) * Double(sample)
        }
        return sum
    }
}

/// Fast-attack, slow-release smoothing so a meter jumps up with speech but
/// settles gently instead of flickering. Time-based, so the feel doesn't depend
/// on the polling rate.
struct AudioLevelSmoother: Equatable {
    /// Time constants in seconds: how quickly the value chases a higher / lower target.
    let attack: Float
    let release: Float
    private(set) var value: Float = 0

    init(attack: Float = 0.05, release: Float = 0.35) {
        self.attack = attack
        self.release = release
    }

    /// Moves toward `target` (0...1) over `dt` seconds and returns the new value.
    @discardableResult
    mutating func update(target: Float, dt: Float) -> Float {
        guard dt > 0 else { return value }
        let clamped = min(1, max(0, target.isFinite ? target : 0))
        let tau = clamped > value ? attack : release
        let coefficient = tau > 0 ? 1 - exp(-dt / tau) : 1
        value += (clamped - value) * coefficient
        return value
    }

    mutating func reset() {
        value = 0
    }
}

/// Hand-off for the latest raw meter position between an audio thread (writer)
/// and the main actor (reader). One short lock-guarded store per buffer; no
/// allocation, no actor hop. A reading older than `maxAge` counts as silence,
/// so a stream that stops delivering buffers doesn't leave the meter stuck.
final class LevelMeterSource: Sendable {
    private struct State {
        var level: Float = 0
        var stamp: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func publish(_ level: Float) {
        let now = DispatchTime.now().uptimeNanoseconds
        state.withLock {
            $0.level = level
            $0.stamp = now
        }
    }

    func latest(maxAge: TimeInterval = 0.4) -> Float {
        let now = DispatchTime.now().uptimeNanoseconds
        let snapshot = state.withLock { $0 }
        guard snapshot.stamp != 0, now >= snapshot.stamp,
              Double(now - snapshot.stamp) / 1_000_000_000 <= maxAge else { return 0 }
        return snapshot.level
    }

    func reset() {
        state.withLock { $0 = State() }
    }
}
