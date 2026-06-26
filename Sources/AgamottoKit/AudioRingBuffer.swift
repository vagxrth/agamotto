import Foundation

/// In-memory PCM ring for one audio source. Each appended chunk is tagged with the
/// host-clock time of its first sample, so a save can extract an exact `[start, start+dur)`
/// window and place every sample at its true position (missing ranges read as silence).
/// Retains roughly `retainSeconds` of audio; older chunks are evicted.
public final class AudioRingBuffer: @unchecked Sendable {
    public let sampleRate: Double
    public let channels: Int

    private struct Chunk {
        let startTime: Double      // host-clock seconds of the first frame
        let samples: [Float]       // interleaved
    }

    private let retainSeconds: Double
    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var appendedChunkCount = 0

    public init(sampleRate: Double, channels: Int, retainSeconds: Double) {
        self.sampleRate = sampleRate
        self.channels = max(channels, 1)
        self.retainSeconds = retainSeconds
    }

    public func append(samples: [Float], startTime: Double) {
        guard !samples.isEmpty else { return }
        lock.lock()
        chunks.append(Chunk(startTime: startTime, samples: samples))
        appendedChunkCount += 1

        let endTime = startTime + Double(samples.count / channels) / sampleRate
        let cutoff = endTime - retainSeconds
        while let first = chunks.first {
            let firstEnd = first.startTime + Double(first.samples.count / channels) / sampleRate
            if firstEnd < cutoff { chunks.removeFirst() } else { break }
        }
        lock.unlock()
    }

    public func chunkCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return appendedChunkCount
    }

    /// Interleaved Float window covering `[start, start + duration)`. Each retained chunk is
    /// copied to its host-time-relative offset; gaps remain silent.
    public func window(start windowStart: Double, duration: Double) -> [Float] {
        let frameCount = max(Int((duration * sampleRate).rounded()), 0)
        var output = [Float](repeating: 0, count: frameCount * channels)
        guard frameCount > 0 else { return output }

        lock.lock()
        let snapshot = chunks
        lock.unlock()

        for chunk in snapshot {
            let chunkFrames = chunk.samples.count / channels
            let offsetFrame = Int(((chunk.startTime - windowStart) * sampleRate).rounded())
            if offsetFrame >= frameCount || offsetFrame + chunkFrames <= 0 { continue }

            let firstSourceFrame = max(0, -offsetFrame)
            let lastSourceFrame = min(chunkFrames, frameCount - offsetFrame)
            var sourceFrame = firstSourceFrame
            while sourceFrame < lastSourceFrame {
                let destinationFrame = offsetFrame + sourceFrame
                for channel in 0..<channels {
                    output[destinationFrame * channels + channel] = chunk.samples[sourceFrame * channels + channel]
                }
                sourceFrame += 1
            }
        }
        return output
    }
}
