import Foundation

/// The trailing window chosen for a save: the video segment files plus the absolute
/// host-clock start time and total duration, so the audio rings can be sampled over the
/// exact same window.
public struct ReplaySelection: Sendable {
    public let segmentURLs: [URL]
    public let startHostTime: Double
    public let durationSeconds: Double
}

/// Manages the on-disk rolling video-segment ring: file naming, the in-memory index of
/// finalized ("ready") segments, count-based pruning, and trailing-window selection.
/// Thread-safe — the recorder registers/prunes from its capture + finalizer queues while a
/// save reads concurrently.
public final class ReplaySegmentStore: @unchecked Sendable {
    public let directory: URL
    public let sessionID: String

    private struct Segment {
        let url: URL
        let index: Int
        let durationSeconds: Double
        let startHostTime: Double
    }

    private let lock = NSLock()
    private var ready: [Segment] = []

    public init(directory: URL) throws {
        self.directory = directory
        self.sessionID = String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 16)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanDirectory()
    }

    public func segmentURL(index: Int) -> URL {
        directory.appendingPathComponent(String(format: "seg_%@_%06d.mp4", sessionID, index))
    }

    public func registerReady(url: URL, index: Int, durationSeconds: Double, startHostTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        ready.append(Segment(url: url, index: index, durationSeconds: durationSeconds, startHostTime: startHostTime))
        ready.sort { $0.index < $1.index }
    }

    public func fillSeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return ready.reduce(0) { $0 + $1.durationSeconds }
    }

    public func readyCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return ready.count
    }

    /// Drop oldest segments (and their files) beyond `keepCount` — the ring eviction.
    public func prune(keepCount: Int) {
        lock.lock()
        guard ready.count > keepCount else { lock.unlock(); return }
        let removeCount = ready.count - keepCount
        let removed = Array(ready.prefix(removeCount))
        ready.removeFirst(removeCount)
        lock.unlock()

        for segment in removed {
            try? FileManager.default.removeItem(at: segment.url)
        }
    }

    /// Newest-trailing segments whose combined duration covers at least `seconds`. Whole-
    /// segment selection keeps the window keyframe-aligned (every segment starts on a
    /// keyframe) so the save can stream-copy the video.
    public func selectTrailing(seconds: Double) -> ReplaySelection {
        lock.lock()
        defer { lock.unlock() }
        var accumulated = 0.0
        var selected: [Segment] = []
        for segment in ready.reversed() {
            selected.append(segment)
            accumulated += segment.durationSeconds
            if accumulated >= seconds { break }
        }
        let ordered = Array(selected.reversed())
        return ReplaySelection(
            segmentURLs: ordered.map(\.url),
            startHostTime: ordered.first?.startHostTime ?? 0,
            durationSeconds: ordered.reduce(0) { $0 + $1.durationSeconds }
        )
    }

    private func cleanDirectory() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.pathExtension == "mp4" {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
