import Foundation

/// Holds the system-audio and microphone PCM rings and produces the mixed window for a save.
/// Mixing happens here, offline, against the saved video's host-time window — so there's no
/// real-time mix to drift and no need for silence-filler tricks.
public final class ReplayAudioStore: @unchecked Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let system: AudioRingBuffer
    public let microphone: AudioRingBuffer

    public init(sampleRate: Double = 48_000, channels: Int = 2, retainSeconds: Double) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.system = AudioRingBuffer(sampleRate: sampleRate, channels: channels, retainSeconds: retainSeconds)
        self.microphone = AudioRingBuffer(sampleRate: sampleRate, channels: channels, retainSeconds: retainSeconds)
    }

    /// Interleaved Float mix of the window. Mic is scaled by `micGainDb` and summed into the
    /// system audio, with a hard clamp to [-1, 1].
    public func mixedWindow(start: Double, duration: Double, includeMic: Bool, micGainDb: Float) -> [Float] {
        var mix = system.window(start: start, duration: duration)
        guard includeMic else { return mix }

        let mic = microphone.window(start: start, duration: duration)
        let gain = powf(10, micGainDb / 20)
        let count = min(mix.count, mic.count)
        var index = 0
        while index < count {
            let summed = mix[index] + mic[index] * gain
            mix[index] = max(-1, min(1, summed))
            index += 1
        }
        return mix
    }
}
