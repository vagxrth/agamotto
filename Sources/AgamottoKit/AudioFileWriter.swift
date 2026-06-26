import AVFoundation
import Foundation

/// Writes an interleaved Float32 buffer to an AAC `.m4a`. The mixed save window is encoded
/// once, here, then handed to the muxer as the clip's audio track. Using `AVAudioFile`
/// (PCM in, AAC out) keeps this far simpler than hand-rolling CMSampleBuffers.
enum AudioFileWriter {
    static func writeM4A(interleaved: [Float], sampleRate: Double, channels: Int, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)

        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            throw ReplayExportError.exportFailed("could not build audio processing format")
        }

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 160_000,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let totalFrames = interleaved.count / channels
        guard totalFrames > 0 else { return }

        let chunkFrames = 8_192
        var frameIndex = 0
        while frameIndex < totalFrames {
            let framesThisChunk = min(chunkFrames, totalFrames - frameIndex)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: AVAudioFrameCount(framesThisChunk)
            ), let channelData = buffer.floatChannelData else { break }
            buffer.frameLength = AVAudioFrameCount(framesThisChunk)

            for channel in 0..<channels {
                let destination = channelData[channel]
                for i in 0..<framesThisChunk {
                    destination[i] = interleaved[(frameIndex + i) * channels + channel]
                }
            }
            try file.write(from: buffer)
            frameIndex += framesThisChunk
        }
    }
}
