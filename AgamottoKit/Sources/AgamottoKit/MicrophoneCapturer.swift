import AVFoundation
import CoreMedia
import Foundation

public enum MicrophoneCaptureError: Error, CustomStringConvertible {
    case noDevice
    case cannotConfigure(String)

    public var description: String {
        switch self {
        case .noDevice: "No microphone device available."
        case .cannotConfigure(let reason): "Microphone capture setup failed: \(reason)"
        }
    }
}

/// Captures the default microphone via `AVCaptureSession` (the macOS 14-compatible path;
/// SCK-native mic is 15+) and pushes interleaved Float32 samples into an `AudioRingBuffer`,
/// timestamped on the same host clock as the video + system audio.
public final class MicrophoneCapturer: NSObject, @unchecked Sendable {
    private let ring: AudioRingBuffer
    private let channels: Int
    private let sampleRate: Double
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.agamotto.mic", qos: .userInitiated)

    public private(set) var isRunning = false

    public init(ring: AudioRingBuffer) {
        self.ring = ring
        self.channels = ring.channels
        self.sampleRate = ring.sampleRate
        super.init()
    }

    public func start() throws {
        guard !isRunning else { return }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw MicrophoneCaptureError.noDevice
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw MicrophoneCaptureError.cannotConfigure("input: \(error.localizedDescription)")
        }

        let output = AVCaptureAudioDataOutput()
        // Request exactly the ring's format so no resampling is needed downstream.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MicrophoneCaptureError.cannotConfigure("cannot add input")
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicrophoneCaptureError.cannotConfigure("cannot add output")
        }
        session.addOutput(output)
        session.commitConfiguration()

        session.startRunning()
        isRunning = session.isRunning
        if !isRunning {
            throw MicrophoneCaptureError.cannotConfigure("session did not start")
        }
    }

    public func stop() {
        guard isRunning else { return }
        session.stopRunning()
        isRunning = false
    }
}

extension MicrophoneCapturer: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let samples = AudioSampleExtraction.interleavedFloat32(from: sampleBuffer, channels: channels) else { return }
        ring.append(samples: samples, startTime: sampleBuffer.presentationTimeStamp.seconds)
    }
}
