import CoreMedia
import CoreVideo

/// Builds a fresh `CMSampleBuffer` around an existing pixel buffer with explicit timing.
///
/// The CFR pacer uses this to (re)emit the most recent frame on a fixed 1/fps cadence —
/// including duplicating the last frame when ScreenCaptureKit has delivered nothing new
/// (static screen). Each emitted buffer gets a new presentation timestamp so the encoder
/// sees a strictly-increasing, constant-rate stream.
enum PacedSampleBufferFactory {
    static func make(imageBuffer: CVImageBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }
}
