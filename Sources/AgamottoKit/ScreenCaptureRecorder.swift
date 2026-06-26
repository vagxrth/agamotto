import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Diagnostics collected during a capture run — used by the Phase 0 spike to prove the
/// pipeline and to surface the behaviors that drive later design (idle frames → CFR pacer,
/// drops → backpressure handling).
public struct CaptureDiagnostics: Sendable {
    public var videoFramesAppended = 0
    public var incompleteFramesSkipped = 0
    public var droppedNotReady = 0
    public var audioBuffersAppended = 0
    public var durationSeconds = 0.0
    public var effectiveFps = 0.0
    public var maxInterFrameGapSeconds = 0.0
    public var outputURL: URL?
    public var fileSizeBytes: Int64 = 0
    public var errorMessage: String?
}

public enum CaptureError: Error, CustomStringConvertible {
    case noDisplay
    case writerSetupFailed(String)

    public var description: String {
        switch self {
        case .noDisplay: "No capturable display found."
        case .writerSetupFailed(let message): "AVAssetWriter setup failed: \(message)"
        }
    }
}

/// Minimal end-to-end recorder: ScreenCaptureKit (main display + system audio) →
/// AVAssetWriter (H.264 + AAC) → .mp4. Single-file, no segment ring yet — that's Phase 1.
/// All mutable state is confined to `queue`; the class is `@unchecked Sendable` because SCK
/// retains it as a delegate across threads and we synchronize manually.
public final class ScreenCaptureRecorder: NSObject, @unchecked Sendable {
    private let config: CaptureConfig
    private let outputURL: URL
    private let queue = DispatchQueue(label: "com.agamotto.capture", qos: .userInitiated)

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    private var sessionStarted = false
    private var sessionStartPTS = CMTime.zero
    private var lastVideoPTS: CMTime?

    private var diagnostics = CaptureDiagnostics()
    private var streamError: String?

    public init(config: CaptureConfig, outputURL: URL) {
        self.config = config
        self.outputURL = outputURL
        super.init()
    }

    public func start() async throws {
        try prepareWriter()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first
        else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let (width, height) = config.resolution.dimensions

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.showsCursor = true
        streamConfig.queueDepth = 5
        streamConfig.capturesAudio = config.capturesSystemAudio
        streamConfig.sampleRate = config.audioSampleRate
        streamConfig.channelCount = config.audioChannels

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if config.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    public func stop() async -> CaptureDiagnostics {
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                queue.sync {
                    if streamError == nil { streamError = "stopCapture: \(error.localizedDescription)" }
                }
            }
        }

        await finishWriting()

        return queue.sync {
            var result = diagnostics
            result.outputURL = outputURL
            result.errorMessage = streamError ?? writer?.error?.localizedDescription
            if sessionStarted, let last = lastVideoPTS {
                result.durationSeconds = (last - sessionStartPTS).seconds
                if result.durationSeconds > 0 {
                    result.effectiveFps = Double(result.videoFramesAppended) / result.durationSeconds
                }
            }
            if let size = try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64 {
                result.fileSizeBytes = size
            }
            return result
        }
    }

    private func prepareWriter() throws {
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw CaptureError.writerSetupFailed(error.localizedDescription)
        }

        let (width, height) = config.resolution.dimensions
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.resolution.videoBitrateKbps * 1_000,
                // ~1s keyframe cadence; Phase 1 will tighten this to the segment length.
                AVVideoMaxKeyFrameIntervalKey: config.fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoExpectedSourceFrameRateKey: config.fps,
                AVVideoAllowFrameReorderingKey: false, // low-latency, no B-frames
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw CaptureError.writerSetupFailed("cannot add video input")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if config.capturesSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: config.audioSampleRate,
                AVNumberOfChannelsKey: config.audioChannels,
                AVEncoderBitRateKey: 128_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
    }

    private func finishWriting() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard let writer = self.writer, writer.status == .writing else {
                    continuation.resume()
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                writer.finishWriting { continuation.resume() }
            }
        }
    }
}

extension ScreenCaptureRecorder: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            if self.streamError == nil { self.streamError = "stream stopped: \(error.localizedDescription)" }
        }
    }
}

extension ScreenCaptureRecorder: SCStreamOutput {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: handleVideo(sampleBuffer)
        case .audio: handleAudio(sampleBuffer)
        default: break
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        // SCK only delivers a "complete" frame when the screen actually changes; on a static
        // screen it sends idle/blank status frames (or nothing). Count those — they're the
        // reason a constant-frame-rate pacer (duplicate-last-frame) is needed in Phase 1.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let raw = info[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw),
            status != .complete
        {
            diagnostics.incompleteFramesSkipped += 1
            return
        }

        guard let writer, let videoInput else { return }
        let pts = sampleBuffer.presentationTimeStamp

        if !sessionStarted {
            guard writer.startWriting() else {
                if streamError == nil {
                    streamError = "startWriting failed: \(writer.error?.localizedDescription ?? "unknown")"
                }
                return
            }
            writer.startSession(atSourceTime: pts)
            sessionStartPTS = pts
            sessionStarted = true
        }

        if let last = lastVideoPTS {
            let gap = (pts - last).seconds
            if gap > diagnostics.maxInterFrameGapSeconds { diagnostics.maxInterFrameGapSeconds = gap }
        }
        lastVideoPTS = pts

        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
            diagnostics.videoFramesAppended += 1
        } else {
            diagnostics.droppedNotReady += 1
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        // Drop pre-roll audio that precedes the first video frame so A/V starts aligned.
        guard sessionStarted, let audioInput else { return }
        let pts = sampleBuffer.presentationTimeStamp
        guard pts >= sessionStartPTS, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
        diagnostics.audioBuffersAppended += 1
    }
}
