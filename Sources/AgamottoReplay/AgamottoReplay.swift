import AgamottoKit
import Foundation

@main
struct AgamottoReplay {
    static func main() async {
        print("""
        ────────────────────────────────────────────
         Agamotto · Phase 2 replay buffer (video + system + mic)
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
        if mic != .granted {
            print("  (Mic not granted — the clip will contain system audio only.)")
        }

        let runSeconds = 20.0
        let saveSeconds = 10.0
        let segmentSeconds = 1.0
        let bufferSeconds = 30.0
        let captureMic = (mic == .granted)

        let config = CaptureConfig(
            resolution: .p1080,
            fps: 60,
            capturesSystemAudio: true,
            captureMicrophone: captureMic,
            micGainDb: 6
        )

        let liveDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Agamotto/live", isDirectory: true)
        let outputURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/agamotto-replay-\(Int(Date().timeIntervalSince1970)).mp4")

        do {
            let store = try ReplaySegmentStore(directory: liveDirectory)
            let audioStore = ReplayAudioStore(
                sampleRate: Double(config.audioSampleRate),
                channels: Int(config.audioChannels),
                retainSeconds: bufferSeconds + 5
            )
            let recorder = SegmentRecorder(
                config: config,
                store: store,
                audioStore: audioStore,
                segmentSeconds: segmentSeconds,
                bufferSeconds: bufferSeconds
            )

            print("""

            ▶︎ Rolling \(Int(segmentSeconds))s video segments + audio rings for \(Int(runSeconds))s.
              Play a video (system audio) and talk (mic) so there's something to capture…
            """)
            try await recorder.start()
            try await Task.sleep(for: .seconds(runSeconds))

            print("⏺  Saving the last \(Int(saveSeconds))s (video + mixed audio)…")
            await recorder.flushForSave()
            let selection = store.selectTrailing(seconds: saveSeconds)
            let clip = try await ReplayClipMuxer.save(
                selection: selection,
                audioStore: audioStore,
                includeMic: captureMic,
                micGainDb: config.micGainDb,
                to: outputURL
            )

            let diagnostics = recorder.diagnosticsSnapshot()
            await recorder.stop()

            report(diagnostics: diagnostics, clip: clip, selection: selection, saveSeconds: saveSeconds, captureMic: captureMic)
        } catch {
            print("✗ Replay demo failed: \(error)")
        }
    }

    private static func report(
        diagnostics: RingDiagnostics,
        clip: ClipInfo,
        selection: ReplaySelection,
        saveSeconds: Double,
        captureMic: Bool
    ) {
        print("""

        ── Ring ────────────────────────────────────
        Source frames received : \(diagnostics.sourceFramesReceived)
        Paced frames written   : \(diagnostics.pacedFramesAppended)  (CFR output — steady regardless of source rate)
        Duplicated frames      : \(diagnostics.duplicatedFrames)  (static-screen ticks held by the pacer)
        Segments rotated       : \(diagnostics.segmentsRotated)
        Ring at save           : \(String(format: "%.1f", diagnostics.ringFillSeconds))s across \(diagnostics.ringSegmentCount) segments

        ── Audio ───────────────────────────────────
        System audio chunks    : \(diagnostics.systemAudioChunks)
        Mic enabled / running  : \(captureMic ? "yes" : "no") / \(diagnostics.micRunning ? "yes" : "no")
        Mic audio chunks       : \(diagnostics.micAudioChunks)

        ── Saved clip ──────────────────────────────
        Window selected        : \(String(format: "%.2f", selection.durationSeconds))s from \(selection.segmentURLs.count) segments (requested \(Int(saveSeconds))s)
        Clip duration          : \(String(format: "%.2f", clip.durationSeconds))s
        Output file            : \(clip.url.path)
        File size              : \(ByteCountFormatter.string(fromByteCount: clip.sizeBytes, countStyle: .file))
        """)
        if let error = diagnostics.errorMessage {
            print("Note                   : \(error)")
        }
        print("────────────────────────────────────────────")
        if clip.sizeBytes > 0, clip.durationSeconds >= saveSeconds - 2 {
            print("✓ Phase 2 validated: continuous ring → clip with synced video + mixed audio. Open it and check A/V sync.")
        } else {
            print("✗ Clip looks short/empty — check the notes above.")
        }
    }
}
