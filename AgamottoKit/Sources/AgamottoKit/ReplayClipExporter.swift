import AVFoundation
import Foundation

public struct ClipInfo: Sendable {
    public let url: URL
    public let durationSeconds: Double
    public let sizeBytes: Int64
}

public enum ReplayExportError: Error, CustomStringConvertible {
    case noSegments
    case cannotCreateSession
    case exportFailed(String)

    public var description: String {
        switch self {
        case .noSegments: "No segments to export."
        case .cannotCreateSession: "Could not create AVAssetExportSession."
        case .exportFailed(let message): "Export failed: \(message)"
        }
    }
}

/// Concatenates the selected trailing segments into one clip via `AVMutableComposition`,
/// then exports. Tries passthrough first (stream-copy — the instant "fast save"); falls back
/// to a re-encode only if passthrough can't handle the concat.
public enum ReplayClipExporter {
    public static func exportTrailing(segments: [URL], to output: URL) async throws -> ClipInfo {
        guard !segments.isEmpty else { throw ReplayExportError.noSegments }

        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        for url in segments {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration.seconds > 0 else { continue }
            try await composition.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: asset,
                at: cursor
            )
            cursor = cursor + duration
        }

        do {
            try await runExport(composition, to: output, preset: AVAssetExportPresetPassthrough)
        } catch {
            // Passthrough can't concat these params — re-encode as a fallback (Phase 4 will
            // make the "smooth" path first-class; here it's just a safety net).
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
