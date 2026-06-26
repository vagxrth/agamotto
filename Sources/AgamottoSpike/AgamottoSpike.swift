import AgamottoKit
import AVFoundation
import Foundation

@main
struct AgamottoSpike {
    static func main() async {
        print("""
        ────────────────────────────────────────────
         Agamotto · Phase 0 capture spike
        ────────────────────────────────────────────
        """)

        // 1) Screen Recording — required for any capture.
        let screenGranted = Permissions.ensureScreenRecording()
        print("• Screen Recording permission: \(screenGranted ? "GRANTED" : "NOT GRANTED")")
        guard screenGranted else {
            print("""

            ⚠️  Screen Recording is required. When run as a CLI, macOS attributes the grant to
                the host app (Terminal/Xcode). Enable it under:
                  System Settings ▸ Privacy & Security ▸ Screen Recording
                then re-run:  swift run AgamottoSpike
            """)
            return
        }

        // 2) Microphone — validate the permission flow now. This spike records video + system
        //    audio only; mic capture + live mix is Phase 2.
        let mic = await Permissions.ensureMicrophone()
        print("• Microphone permission: \(mic)")
        print("  (Phase 0 records video + system audio; mic capture/mix lands in Phase 2.)")

        // 3) Capture 10 seconds → ~/Downloads/agamotto-spike-<timestamp>.mp4
        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/agamotto-spike-\(stamp).mp4")

        let config = CaptureConfig.default1080p60
        let (width, height) = config.resolution.dimensions
        let recorder = ScreenCaptureRecorder(config: config, outputURL: url)

        do {
            print("\n▶︎ Capturing \(width)×\(height) @ \(config.fps)fps for 10s — move some windows around to generate motion…")
            try await recorder.start()
            try await Task.sleep(for: .seconds(10))
            let diagnostics = await recorder.stop()
            report(diagnostics, config: config)
        } catch {
            print("✗ Capture failed: \(error)")
        }
    }

    private static func report(_ diagnostics: CaptureDiagnostics, config: CaptureConfig) {
        let gapMs = diagnostics.maxInterFrameGapSeconds * 1_000
        print("""

        ── Results ─────────────────────────────────
        Video frames written  : \(diagnostics.videoFramesAppended)
        Idle frames skipped   : \(diagnostics.incompleteFramesSkipped)  (SCK sends nothing new on a static screen → why Phase 1 needs a CFR pacer)
        Frames dropped (busy) : \(diagnostics.droppedNotReady)
        Audio buffers written : \(diagnostics.audioBuffersAppended)
        Duration              : \(String(format: "%.2f", diagnostics.durationSeconds))s
        Effective FPS         : \(String(format: "%.1f", diagnostics.effectiveFps))  (target \(config.fps))
        Max inter-frame gap   : \(String(format: "%.0f", gapMs))ms
        Output file           : \(diagnostics.outputURL?.path ?? "—")
        File size             : \(ByteCountFormatter.string(fromByteCount: diagnostics.fileSizeBytes, countStyle: .file))
        """)
        if let error = diagnostics.errorMessage {
            print("Writer/stream note    : \(error)")
        }
        print("────────────────────────────────────────────")
        if diagnostics.videoFramesAppended > 0, diagnostics.fileSizeBytes > 0 {
            print("✓ Pipeline validated: SCK → AVAssetWriter → playable .mp4. Open the file to confirm.")
        } else {
            print("✗ No frames written. Check that Screen Recording is granted to the host app, then re-run.")
        }
    }
}
