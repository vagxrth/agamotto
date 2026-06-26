import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public struct RingDiagnostics: Sendable {
    public var sourceFramesReceived = 0
    public var pacedFramesAppended = 0
    public var duplicatedFrames = 0   // pacer ticks where no new source frame had arrived
    public var segmentsRotated = 0
    public var audioBuffersAppended = 0
    public var ringFillSeconds = 0.0
    public var ringSegmentCount = 0
    public var errorMessage: String?
}

/// The always-on replay buffer: ScreenCaptureKit feeds the latest frame; a constant-rate
/// pacer emits it (or a duplicate of the last one) every 1/fps into the active segment; the
/// recorder rotates to a new ~`segmentSeconds` MP4 file on a cadence and prunes old ones.
/// Each segment is a fresh writer, so it begins on an IDR keyframe — the ring is
/// keyframe-aligned for free, which lets saves stream-copy.
///
/// All mutable state lives on `queue` (SCK sample handlers + pacer ticks share it, so no
/// locks); finalize/prune of rotated-out segments hops to `finalizerQueue`.
public final class SegmentRecorder: NSObject, @unchecked Sendable {
    private let config: CaptureConfig
    private let store: ReplaySegmentStore
    private let segmentSeconds: Double
    private let segmentDuration: CMTime
    private let keepCount: Int

    private let queue = DispatchQueue(label: "com.agamotto.ring.capture", qos: .userInitiated)
    private let finalizerQueue = DispatchQueue(label: "com.agamotto.ring.finalizer", qos: .utility)
    private let hostClock = CMClockGetHostTimeClock()

    private var stream: SCStream?
    private var pacerTimer: DispatchSourceTimer?

    // Active segment (on `queue`)
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var segmentIndex = -1
    private var segmentStartPTS: CMTime?
    private var segmentFrameCount = 0
    private var activeURL: URL?

    // Latest source frame (on `queue`)
    private var latestImageBuffer: CVImageBuffer?
    private var hasFreshFrame = false

    private var diagnostics = RingDiagnostics()

    public init(config: CaptureConfig, store: ReplaySegmentStore, segmentSeconds: Double, bufferSeconds: Double) {
        self.config = config
        self.store = store
        self.segmentSeconds = segmentSeconds
        self.segmentDuration = CMTime(seconds: segmentSeconds, preferredTimescale: 600)
        // Keep enough segments to cover the buffer window, plus a small safety margin.
        self.keepCount = Int((bufferSeconds / segmentSeconds).rounded(.up)) + 3
        super.init()
    }

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first
        else {
            throw CaptureError.noDisplay
        }

        let (width, height) = config.resolution.dimensions
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.showsCursor = true
        streamConfig.queueDepth = 6
        streamConfig.capturesAudio = config.capturesSystemAudio
        streamConfig.sampleRate = config.audioSampleRate
        streamConfig.channelCount = config.audioChannels

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if config.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        self.stream = stream

        // CFR pacer: ticks on the same serial queue as the sample handlers.
        let interval = 1.0 / Double(config.fps)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.onPacerTick() }
        self.pacerTimer = timer
        timer.resume()

        try await stream.startCapture()
    }

    public func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.pacerTimer?.cancel()
                self.pacerTimer = nil
                continuation.resume()
            }
        }
        if let stream {
            try? await stream.stopCapture()
        }
        // Finalize whatever is in the active segment.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard let writer = self.writer, writer.status == .writing, let url = self.activeURL else {
                    continuation.resume()
                    return
                }
                let index = self.segmentIndex
                let duration = Double(self.segmentFrameCount) / Double(self.config.fps)
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.writer = nil
                writer.finishWriting {
                    self.store.registerReady(url: url, index: index, durationSeconds: duration)
                    continuation.resume()
                }
            }
        }
    }

    /// Finalize the in-progress segment so footage up to *now* is saveable, then immediately
    /// start a fresh segment so capture continues without a gap. Awaits the finalize so the
    /// segment file is complete before a save composes it.
    public func flushForSave() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard let oldWriter = self.writer, oldWriter.status == .writing, let oldURL = self.activeURL else {
                    continuation.resume()
                    return
                }
                let oldVideo = self.videoInput
                let oldAudio = self.audioInput
                let oldIndex = self.segmentIndex
                let duration = Double(self.segmentFrameCount) / Double(self.config.fps)

                let now = CMClockGetTime(self.hostClock)
                self.startNewSegment(at: now)

                oldVideo?.markAsFinished()
                oldAudio?.markAsFinished()
                oldWriter.finishWriting {
                    self.store.registerReady(url: oldURL, index: oldIndex, durationSeconds: duration)
                    continuation.resume()
                }
            }
        }
    }

    public func diagnosticsSnapshot() -> RingDiagnostics {
        queue.sync {
            var snapshot = diagnostics
            snapshot.ringFillSeconds = store.fillSeconds()
            snapshot.ringSegmentCount = store.readyCount()
            return snapshot
        }
    }

    // MARK: - Pacer (on `queue`)

    private func onPacerTick() {
        guard let latest = latestImageBuffer else { return } // nothing captured yet
        let now = CMClockGetTime(hostClock)

        if writer == nil {
            startNewSegment(at: now)
        } else if let start = segmentStartPTS, (now - start) >= segmentDuration {
            rotateSegment(at: now)
        }

        guard let videoInput, videoInput.isReadyForMoreMediaData else {
            hasFreshFrame = false
            return
        }
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        guard let sampleBuffer = PacedSampleBufferFactory.make(imageBuffer: latest, pts: now, duration: frameDuration) else {
            return
        }
        videoInput.append(sampleBuffer)
        segmentFrameCount += 1
        diagnostics.pacedFramesAppended += 1
        if !hasFreshFrame { diagnostics.duplicatedFrames += 1 }
        hasFreshFrame = false
    }

    private func startNewSegment(at start: CMTime) {
        segmentIndex += 1
        let url = store.segmentURL(index: segmentIndex)
        guard let (writer, videoInput, audioInput) = makeSegmentWriter(url: url) else {
            diagnostics.errorMessage = diagnostics.errorMessage ?? "failed to create segment writer"
            return
        }
        guard writer.startWriting() else {
            diagnostics.errorMessage = diagnostics.errorMessage
                ?? "startWriting failed: \(writer.error?.localizedDescription ?? "unknown")"
            return
        }
        writer.startSession(atSourceTime: start)
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.activeURL = url
        self.segmentStartPTS = start
        self.segmentFrameCount = 0
    }

    private func rotateSegment(at now: CMTime) {
        guard let oldWriter = writer, let oldURL = activeURL else {
            startNewSegment(at: now)
            return
        }
        let oldVideo = videoInput
        let oldAudio = audioInput
        let oldIndex = segmentIndex
        let duration = Double(segmentFrameCount) / Double(config.fps)

        // Start the next segment first so the pacer keeps appending without a gap.
        startNewSegment(at: now)
        diagnostics.segmentsRotated += 1

        oldVideo?.markAsFinished()
        oldAudio?.markAsFinished()
        oldWriter.finishWriting { [weak self] in
            guard let self else { return }
            self.store.registerReady(url: oldURL, index: oldIndex, durationSeconds: duration)
            self.finalizerQueue.async { self.store.prune(keepCount: self.keepCount) }
        }
    }

    private func makeSegmentWriter(url: URL) -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInput?)? {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let (width, height) = config.resolution.dimensions
        let keyFrameInterval = max(Int((Double(config.fps) * segmentSeconds).rounded()), 1)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.resolution.videoBitrateKbps * 1_000,
                AVVideoMaxKeyFrameIntervalKey: keyFrameInterval,
                AVVideoMaxKeyFrameIntervalDurationKey: segmentSeconds,
                AVVideoExpectedSourceFrameRateKey: config.fps,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { return nil }
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
        return (writer, videoInput, audioInput)
    }
}

extension SegmentRecorder: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            if self.diagnostics.errorMessage == nil {
                self.diagnostics.errorMessage = "stream stopped: \(error.localizedDescription)"
            }
        }
    }
}

extension SegmentRecorder: SCStreamOutput {
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

    /// Only stash the latest *complete* frame; the pacer (not this callback) drives output.
    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let raw = info[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw),
            status != .complete
        {
            return
        }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestImageBuffer = imageBuffer
        hasFreshFrame = true
        diagnostics.sourceFramesReceived += 1
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput, let start = segmentStartPTS else { return }
        let pts = sampleBuffer.presentationTimeStamp
        guard pts >= start, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
        diagnostics.audioBuffersAppended += 1
    }
}
