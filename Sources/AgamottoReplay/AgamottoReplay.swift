import AgamottoKit
import Foundation

@main
struct AgamottoReplay {
    static func main() async {
        print("""
        ────────────────────────────────────────────
         Agamotto · Phase 1 replay-buffer demo
        ────────────────────────────────────────────
        """)

        guard Permissions.ensureScreenRecording() else {
            print("""
            ⚠️  Screen Recording is required. Grant it to the host app under
                System Settings ▸ Privacy & Security ▸ Screen Recording, then re-run:
                  swift run AgamottoReplay
            """)
            return
        }
        let mic = await Permissions.ensureMicrophone()
        print("• Screen Recording: GRANTED   • Microphone: \(mic)")

        let runSeconds = 20.0
        let saveSeconds = 10.0
        let segmentSeconds = 1.0
        let bufferSeconds = 30.0

        let liveDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Agamotto/live", isDirectory: true)
        let outputURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/agamotto-replay-\(Int(Date().timeIntervalSince1970)).mp4")

        do {
            let store = try ReplaySegmentStore(directory: liveDirectory)
            let recorder = SegmentRecorder(
                config: .default1080p60,
                store: store,
                segmentSeconds: segmentSeconds,
                bufferSeconds: bufferSeconds
            )

            print("""

            ▶︎ Rolling \(Int(segmentSeconds))s segments into a \(Int(bufferSeconds))s ring for \(Int(runSeconds))s.
              Move windows / play a video so there's motion + audio to capture…
            """)
            try await recorder.start()
            try await Task.sleep(for: .seconds(runSeconds))

            print("⏺  Saving the last \(Int(saveSeconds))s from the ring…")
            await recorder.flushForSave()
            let selected = store.selectTrailing(seconds: saveSeconds)
            let clip = try await ReplayClipExporter.exportTrailing(segments: selected, to: outputURL)

            let diagnostics = recorder.diagnosticsSnapshot()
            await recorder.stop()

            report(diagnostics: diagnostics, clip: clip, selectedSegments: selected.count, saveSeconds: saveSeconds)
        } catch {
            print("✗ Replay demo failed: \(error)")
        }
    }

    private static func report(
        diagnostics: RingDiagnostics,
        clip: ClipInfo,
        selectedSegments: Int,
        saveSeconds: Double
    ) {
        print("""

        ── Ring ────────────────────────────────────
        Source frames received : \(diagnostics.sourceFramesReceived)
        Paced frames written   : \(diagnostics.pacedFramesAppended)  (CFR output — steady regardless of source rate)
        Duplicated frames      : \(diagnostics.duplicatedFrames)  (ticks where the screen hadn't changed → the pacer held the last frame)
        Segments rotated       : \(diagnostics.segmentsRotated)
        Audio buffers written  : \(diagnostics.audioBuffersAppended)
        Ring at save           : \(String(format: "%.1f", diagnostics.ringFillSeconds))s across \(diagnostics.ringSegmentCount) segments

        ── Saved clip ──────────────────────────────
        Requested window       : \(Int(saveSeconds))s   (selected \(selectedSegments) trailing segments)
        Clip duration          : \(String(format: "%.2f", clip.durationSeconds))s
        Output file            : \(clip.url.path)
        File size              : \(ByteCountFormatter.string(fromByteCount: clip.sizeBytes, countStyle: .file))
        """)
        if let error = diagnostics.errorMessage {
            print("Note                   : \(error)")
        }
        print("────────────────────────────────────────────")
        if clip.sizeBytes > 0, clip.durationSeconds >= saveSeconds - Double(2) {
            print("✓ Replay buffer validated: continuous ring → instant 'save last N seconds' clip. Open it to confirm.")
        } else {
            print("✗ Clip looks short/empty — check the notes above.")
        }
    }
}
