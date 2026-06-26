import AgamottoKit
import AppKit
import Combine
import Foundation

/// App-level owner of the capture engine. Keeps a `SegmentRecorder` armed in the background,
/// exposes state for the menu UI, and performs "save last N seconds" on demand.
@MainActor
final class ReplayController: ObservableObject {
    static let shared = ReplayController()

    enum State: Equatable {
        case starting
        case armed
        case saving
        case needsScreenPermission
        case error(String)
    }

    @Published private(set) var state: State = .starting
    @Published private(set) var lastClipURL: URL?
    @Published private(set) var micActive = false

    // Phase 3 keeps these fixed; a settings UI comes later.
    private let replaySeconds = 30.0
    private let bufferSeconds = 120.0
    private let segmentSeconds = 1.0
    private let micGainDb: Float = 6

    private var recorder: SegmentRecorder?
    private var store: ReplaySegmentStore?
    private var audioStore: ReplayAudioStore?
    private var captureMic = false

    private let liveDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Agamotto/live", isDirectory: true)
    private let clipsDirectory: URL = {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Agamotto", isDirectory: true)
    }()

    private init() {}

    var statusText: String {
        switch state {
        case .starting: "Starting…"
        case .armed: micActive ? "Armed · system + mic" : "Armed · system audio"
        case .saving: "Saving replay…"
        case .needsScreenPermission: "Screen Recording permission needed"
        case .error(let message): "Error: \(message)"
        }
    }

    var isArmed: Bool { state == .armed }
    var canSave: Bool { state == .armed }

    // MARK: - Lifecycle

    func start() {
        Task { await startEngine() }
    }

    private func startEngine() async {
        guard recorder == nil else { return }
        state = .starting

        guard Permissions.screenRecordingGranted() else {
            state = .needsScreenPermission
            return
        }

        let micPermission = await Permissions.ensureMicrophone()
        let captureMic = (micPermission == .granted)

        do {
            try? FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
            let store = try ReplaySegmentStore(directory: liveDirectory)
            let audioStore = ReplayAudioStore(sampleRate: 48_000, channels: 2, retainSeconds: bufferSeconds + 5)
            let config = CaptureConfig(
                resolution: .p1080,
                fps: 60,
                capturesSystemAudio: true,
                captureMicrophone: captureMic,
                micGainDb: micGainDb
            )
            let recorder = SegmentRecorder(
                config: config,
                store: store,
                audioStore: audioStore,
                segmentSeconds: segmentSeconds,
                bufferSeconds: bufferSeconds
            )
            try await recorder.start()

            self.store = store
            self.audioStore = audioStore
            self.recorder = recorder
            self.captureMic = captureMic
            self.micActive = captureMic
            self.state = .armed
        } catch {
            self.state = .error(String(describing: error))
        }
    }

    func stop() async {
        await recorder?.stop()
        recorder = nil
        store = nil
        audioStore = nil
    }

    // MARK: - Save

    func saveReplay() {
        guard state == .armed, let recorder, let store, let audioStore else { return }
        state = .saving
        let includeMic = captureMic
        let gain = micGainDb
        let seconds = replaySeconds
        let output = clipsDirectory.appendingPathComponent("Agamotto \(Self.timestamp()).mp4")

        Task {
            await recorder.flushForSave()
            let selection = store.selectTrailing(seconds: seconds)
            do {
                let clip = try await ReplayClipMuxer.save(
                    selection: selection,
                    audioStore: audioStore,
                    includeMic: includeMic,
                    micGainDb: gain,
                    to: output
                )
                self.lastClipURL = clip.url
                NSSound(named: "Glass")?.play()
            } catch {
                self.state = .error("save failed: \(error)")
                return
            }
            self.state = .armed
        }
    }

    func revealLastClip() {
        guard let lastClipURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastClipURL])
    }

    func openClipsFolder() {
        try? FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(clipsDirectory)
    }

    // MARK: - Permissions

    func grantScreenRecording() {
        // Prompts (attributed to Agamotto) and opens the relevant System Settings pane.
        _ = Permissions.ensureScreenRecording()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        // Try to arm once the grant lands; a fresh grant sometimes needs an app relaunch.
        Task {
            try? await Task.sleep(for: .seconds(1))
            if Permissions.screenRecordingGranted(), recorder == nil {
                await startEngine()
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}
