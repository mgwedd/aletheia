import AVFoundation
import CoreMedia

/// Converts a CMSampleBuffer carrying LPCM audio (as delivered by
/// ScreenCaptureKit's `.audio` stream output) into an AVAudioPCMBuffer, so
/// it can be written with a plain AVAudioFile the same way the mic tap
/// buffers are.
extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self) else { return nil }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let numSamples = CMSampleBufferGetNumSamples(self)
        guard numSamples > 0 else { return nil }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(numSamples),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return pcmBuffer
    }
}
