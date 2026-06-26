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
    public var systemAudioChunks = 0
    public var micAudioChunks = 0
    public var micRunning = false
    public var ringFillSeconds = 0.0
    public var ringSegmentCount = 0
    public var errorMessage: String?
}

/// The always-on replay buffer. ScreenCaptureKit feeds the latest frame; a constant-rate
/// pacer emits it (or a duplicate) every 1/fps into the active **video-only** segment; the
/// recorder rotates to a new ~`segmentSeconds` MP4 file on a cadence and prunes old ones.
/// Audio (system via SCK, mic via AVCaptureSession) flows into the `ReplayAudioStore`'s PCM
/// rings, tagged with host-clock time, to be windowed + mixed at save time.
///
/// All video state lives on `queue` (SCK sample handlers + pacer ticks share it); mic samples
/// arrive on the capturer's own queue and go straight into a thread-safe ring.
public final class SegmentRecorder: NSObject, @unchecked Sendable {
    private let config: CaptureConfig
    private let store: ReplaySegmentStore
    private let audioStore: ReplayAudioStore
    private let segmentSeconds: Double
    private let segmentDuration: CMTime
    private let keepCount: Int

    private let queue = DispatchQueue(label: "com.agamotto.ring.capture", qos: .userInitiated)
    private let hostClock = CMClockGetHostTimeClock()

    private var stream: SCStream?
    private var pacerTimer: DispatchSourceTimer?
    private var micCapturer: MicrophoneCapturer?

    // Active segment (on `queue`)
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var segmentIndex = -1
    private var segmentStartPTS: CMTime?
    private var segmentStartHostTime = 0.0
    private var segmentFrameCount = 0
    private var activeURL: URL?

    // Latest source frame (on `queue`)
    private var latestImageBuffer: CVImageBuffer?
    private var hasFreshFrame = false

    private var diagnostics = RingDiagnostics()

    public init(
        config: CaptureConfig,
        store: ReplaySegmentStore,
        audioStore: ReplayAudioStore,
        segmentSeconds: Double,
        bufferSeconds: Double
    ) {
        self.config = config
        self.store = store
        self.audioStore = audioStore
        self.segmentSeconds = segmentSeconds
        self.segmentDuration = CMTime(seconds: segmentSeconds, preferredTimescale: 600)
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

        // Mic runs alongside SCK; best-effort so capture still works if it fails.
        if config.captureMicrophone {
            let capturer = MicrophoneCapturer(ring: audioStore.microphone)
            do {
                try capturer.start()
                self.micCapturer = capturer
            } catch {
                queue.async { self.diagnostics.errorMessage = "mic: \(error.localizedDescription)" }
            }
        }

        let interval = 1.0 / Double(config.fps)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.onPacerTick() }
        self.pacerTimer = timer
        timer.resume()

        try await stream.startCapture()
    }

    public func stop() async {
        micCapturer?.stop()
        micCapturer = nil

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
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard let writer = self.writer, writer.status == .writing, let url = self.activeURL else {
                    continuation.resume()
                    return
                }
                let index = self.segmentIndex
                let startHost = self.segmentStartHostTime
                let duration = Double(self.segmentFrameCount) / Double(self.config.fps)
                self.videoInput?.markAsFinished()
                self.writer = nil
                writer.finishWriting {
                    self.store.registerReady(url: url, index: index, durationSeconds: duration, startHostTime: startHost)
                    continuation.resume()
                }
            }
        }
    }

    /// Finalize the in-progress segment so footage up to *now* is saveable, then immediately
    /// start a fresh one so capture continues without a gap. Awaits the finalize.
    public func flushForSave() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard let oldWriter = self.writer, oldWriter.status == .writing, let oldURL = self.activeURL else {
                    continuation.resume()
                    return
                }
                let oldVideo = self.videoInput
                let oldIndex = self.segmentIndex
                let oldStartHost = self.segmentStartHostTime
                let duration = Double(self.segmentFrameCount) / Double(self.config.fps)

                let now = CMClockGetTime(self.hostClock)
                self.startNewSegment(at: now)

                oldVideo?.markAsFinished()
                oldWriter.finishWriting {
                    self.store.registerReady(url: oldURL, index: oldIndex, durationSeconds: duration, startHostTime: oldStartHost)
                    continuation.resume()
                }
            }
        }
    }

    public func diagnosticsSnapshot() -> RingDiagnostics {
        queue.sync {
            var snapshot = diagnostics
            snapshot.systemAudioChunks = audioStore.system.chunkCount()
            snapshot.micAudioChunks = audioStore.microphone.chunkCount()
            snapshot.micRunning = micCapturer?.isRunning ?? false
            snapshot.ringFillSeconds = store.fillSeconds()
            snapshot.ringSegmentCount = store.readyCount()
            return snapshot
        }
    }

    // MARK: - Pacer (on `queue`)

    private func onPacerTick() {
        guard let latest = latestImageBuffer else { return }
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
        guard let (writer, videoInput) = makeSegmentWriter(url: url) else {
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
        self.activeURL = url
        self.segmentStartPTS = start
        self.segmentStartHostTime = start.seconds
        self.segmentFrameCount = 0
    }

    private func rotateSegment(at now: CMTime) {
        guard let oldWriter = writer, let oldURL = activeURL else {
            startNewSegment(at: now)
            return
        }
        let oldVideo = videoInput
        let oldIndex = segmentIndex
        let oldStartHost = segmentStartHostTime
        let duration = Double(segmentFrameCount) / Double(config.fps)

        startNewSegment(at: now)
        diagnostics.segmentsRotated += 1

        oldVideo?.markAsFinished()
        oldWriter.finishWriting { [weak self] in
            guard let self else { return }
            self.store.registerReady(url: oldURL, index: oldIndex, durationSeconds: duration, startHostTime: oldStartHost)
            self.store.prune(keepCount: self.keepCount)
        }
    }

    private func makeSegmentWriter(url: URL) -> (AVAssetWriter, AVAssetWriterInput)? {
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
        return (writer, videoInput)
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
        case .audio: handleSystemAudio(sampleBuffer)
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

    private func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let samples = AudioSampleExtraction.interleavedFloat32(from: sampleBuffer, channels: config.audioChannels) else { return }
        audioStore.system.append(samples: samples, startTime: sampleBuffer.presentationTimeStamp.seconds)
    }
}
