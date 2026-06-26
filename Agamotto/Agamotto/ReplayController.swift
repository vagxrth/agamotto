import AgamottoKit
import AppKit
import Combine
import Foundation

/// App-level owner of the capture engine. Keeps a `SegmentRecorder` armed in the background,
/// exposes state for the menu UI, and performs "save last N seconds" on demand. Configuration
/// comes from persisted `AppSettings`; a capture-affecting change restarts the engine.
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

    @Published var settings: AppSettings {
        didSet {
            settings.save()
            let previous = oldValue
            Task { await applySettingsChange(from: previous) }
        }
    }

    private let segmentSeconds = 1.0

    private var recorder: SegmentRecorder?
    private var store: ReplaySegmentStore?
    private var audioStore: ReplayAudioStore?

    private let liveDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Agamotto/live", isDirectory: true)
    private var clipsDirectory: URL { settings.outputDirectory }

    private init() {
        settings = AppSettings.load()
    }

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

        let captureMic: Bool
        if settings.includeMicrophone {
            captureMic = await Permissions.ensureMicrophone() == .granted
        } else {
            captureMic = false
        }

        do {
            try? FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
            let store = try ReplaySegmentStore(directory: liveDirectory)
            let audioStore = ReplayAudioStore(
                sampleRate: 48_000,
                channels: 2,
                retainSeconds: Double(settings.bufferSeconds) + 5
            )
            var config = settings.captureConfig
            config.captureMicrophone = captureMic // gate on actual permission
            let recorder = SegmentRecorder(
                config: config,
                store: store,
                audioStore: audioStore,
                segmentSeconds: segmentSeconds,
                bufferSeconds: Double(settings.bufferSeconds)
            )
            try await recorder.start()

            self.store = store
            self.audioStore = audioStore
            self.recorder = recorder
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

    /// Restart capture only when a capture-affecting setting changed (and we're running).
    /// Save-time settings (replay length, mic gain, output folder) are read fresh on save.
    private func applySettingsChange(from previous: AppSettings) async {
        guard recorder != nil, previous.captureSignature != settings.captureSignature else { return }
        await stop()
        await startEngine()
    }

    // MARK: - Save

    func saveReplay() {
        guard state == .armed, let recorder, let store, let audioStore else { return }
        state = .saving
        let includeMic = micActive
        let gain = Float(settings.micGainDb)
        let seconds = Double(settings.replaySeconds)
        let directory = clipsDirectory
        let output = directory.appendingPathComponent("Agamotto \(Self.timestamp()).mp4")

        Task {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
