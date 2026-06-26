import AVFoundation
import CoreMedia

/// Pulls interleaved Float32 samples out of a PCM `CMSampleBuffer`, converting from
/// int16 / non-interleaved layouts and up-/down-mixing channels as needed. Both the SCK
/// system-audio path and the AVCaptureSession mic path funnel through this so the rings
/// always hold a uniform interleaved-float format.
enum AudioSampleExtraction {
    static func interleavedFloat32(from sampleBuffer: CMSampleBuffer, channels: Int) -> [Float]? {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var listSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard sizeStatus == noErr, listSize > 0 else { return nil }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let listPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)

        let fillStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard fillStatus == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
        let sourceChannels = max(Int(asbd.mChannelsPerFrame), 1)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        func sample(_ pointer: UnsafeRawPointer, _ index: Int) -> Float {
            if isFloat, bitsPerChannel == 32 {
                return pointer.assumingMemoryBound(to: Float.self)[index]
            }
            if !isFloat, bitsPerChannel == 16 {
                return Float(pointer.assumingMemoryBound(to: Int16.self)[index]) / Float(Int16.max)
            }
            return 0
        }

        var output = [Float](repeating: 0, count: frameCount * channels)

        if isNonInterleaved {
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    let sourceChannel = min(channel, sourceChannels - 1)
                    guard sourceChannel < buffers.count, let data = buffers[sourceChannel].mData else { return nil }
                    output[frame * channels + channel] = sample(data, frame)
                }
            }
        } else {
            guard let data = buffers.first?.mData else { return nil }
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    let sourceChannel = min(channel, sourceChannels - 1)
                    output[frame * channels + channel] = sample(data, frame * sourceChannels + sourceChannel)
                }
            }
        }
        return output
    }
}
