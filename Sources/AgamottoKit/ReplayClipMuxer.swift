import AVFoundation
import Foundation

/// Builds the final clip: mixes the audio window to AAC, then composes the passthrough video
/// segments with that audio track and exports. Video is never re-encoded; only the (already
/// mixed) audio is encoded, once. Falls back to a full re-encode only if passthrough can't
/// handle the composition.
///
/// Video and audio go into **separate, explicit composition tracks** so they overlay on one
/// timeline. (The `insertTimeRange(of:at:)` convenience method splice-*inserts* instead,
/// which doubles the duration and pushes the video off the audio timeline.)
public enum ReplayClipMuxer {
    public static func save(
        selection: ReplaySelection,
        audioStore: ReplayAudioStore,
        includeMic: Bool,
        micGainDb: Float,
        to output: URL
    ) async throws -> ClipInfo {
        guard !selection.segmentURLs.isEmpty else { throw ReplayExportError.noSegments }

        // 1) Mix the exact host-time window of the saved video, encode to a temp .m4a.
        let mixed = audioStore.mixedWindow(
            start: selection.startHostTime,
            duration: selection.durationSeconds,
            includeMic: includeMic,
            micGainDb: micGainDb
        )
        let tempAudioURL = output.deletingLastPathComponent()
            .appendingPathComponent(".agamotto-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempAudioURL) }

        let haveAudio = !mixed.isEmpty
        if haveAudio {
            try AudioFileWriter.writeM4A(
                interleaved: mixed,
                sampleRate: audioStore.sampleRate,
                channels: audioStore.channels,
                to: tempAudioURL
            )
        }

        // 2) Compose: one video track (segments concatenated) + one audio track (the mix),
        //    overlaid on a shared timeline.
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ReplayExportError.exportFailed("could not create composition video track")
        }

        var cursor = CMTime.zero
        for url in selection.segmentURLs {
            let asset = AVURLAsset(url: url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = try await sourceVideo.load(.timeRange)
            guard range.duration.seconds > 0 else { continue }
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            cursor = cursor + range.duration
        }
        guard cursor.seconds > 0 else {
            throw ReplayExportError.exportFailed("no video found in selected segments")
        }

        if haveAudio {
            let audioAsset = AVURLAsset(url: tempAudioURL)
            if let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first {
                let audioRange = try await sourceAudio.load(.timeRange)
                let usable = CMTimeMinimum(audioRange.duration, cursor)
                if usable.seconds > 0,
                   let audioTrack = composition.addMutableTrack(
                       withMediaType: .audio,
                       preferredTrackID: kCMPersistentTrackID_Invalid
                   ) {
                    try audioTrack.insertTimeRange(
                        CMTimeRange(start: audioRange.start, duration: usable),
                        of: sourceAudio,
                        at: .zero
                    )
                }
            }
        }

        // 3) Export (passthrough first; re-encode fallback).
        do {
            try await runExport(composition, to: output, preset: AVAssetExportPresetPassthrough)
        } catch {
            try await runExport(composition, to: output, preset: AVAssetExportPresetHighestQuality)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        return ClipInfo(url: output, durationSeconds: cursor.seconds, sizeBytes: size)
    }

    private static func runExport(_ asset: AVAsset, to output: URL, preset: String) async throws {
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ReplayExportError.cannotCreateSession
        }
        session.outputURL = output
        session.outputFileType = .mp4

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }

        if session.status != .completed {
            try? FileManager.default.removeItem(at: output)
            throw ReplayExportError.exportFailed(
                session.error?.localizedDescription ?? "status \(session.status.rawValue)"
            )
        }
    }
}
