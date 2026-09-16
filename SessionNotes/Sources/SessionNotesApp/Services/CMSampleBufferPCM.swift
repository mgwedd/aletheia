import AVFoundation
import CoreMedia

/// Converts a CMSampleBuffer carrying LPCM audio (as delivered by
/// ScreenCaptureKit's audio output) into an AVAudioPCMBuffer, so it can be
/// written with a plain AVAudioFile the same way the mic tap buffers are.
/// This mirrors Apple's own ScreenCaptureKit sample code pattern for
/// consuming `.audio` stream output.
extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        guard var absd = self.formatDescription?.audioStreamBasicDescription else { return nil }
        guard let format = AVAudioFormat(streamDescription: &absd) else { return nil }

        var pcmBuffer: AVAudioPCMBuffer?
        do {
            try self.withAudioBufferList(blockBufferMemoryAllocator: kCFAllocatorDefault, flags: []) { audioBufferList, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer) else {
                    return
                }
                buffer.frameLength = AVAudioFrameCount(self.numSamples)
                pcmBuffer = buffer
            }
        } catch {
            return nil
        }
        return pcmBuffer
    }
}
