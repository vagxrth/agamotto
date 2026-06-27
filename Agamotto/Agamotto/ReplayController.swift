import AgamottoKit
import AppKit
import Combine
import Foundation
import KeyboardShortcuts

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
        case paused
        case needsScreenPermission
        case error(String)
    }

    @Published private(set) var state: State = .starting
    @Published private(set) var lastClipURL: URL?
    @Published private(set) var micActive = false
    /// Glyph form of the current save shortcut (e.g. "⌃⌥R"), kept in sync so the menu updates live.
    @Published private(set) var saveShortcutLabel: String = ""
    /// Glyph form of the current pause shortcut, kept in sync for the menu.
    @Published private(set) var pauseShortcutLabel: String = ""

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

    // Recovery
    private var isRestarting = false
    private var pendingRestart = false
    private var restartTimestamps: [Date] = []
    private var displayChangeWork: DispatchWorkItem?

    // Smart Pause: tear the capture session down while DRM/streaming apps are active
    // (manual via hotkey/menu, or automatic when a protected app is frontmost).
    private enum PauseReason { case manual, autoProtected }
    private var pauseReason: PauseReason?
    private var pendingPause: PauseReason?
    private var autoResumeWork: DispatchWorkItem?

    private let liveDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Agamotto/live", isDirectory: true)
    private var clipsDirectory: URL { settings.outputDirectory }

    private init() {
        settings = AppSettings.load()
        refreshShortcutLabels()
        // Restart capture when displays change (resolution, arrangement, monitor add/remove).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDisplayChange() }
        }
        // Auto-pause while a DRM/streaming app is frontmost — macOS blanks protected video
        // whenever the screen is being captured, so we get out of the way.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in self?.handleFrontmostChange(bundleID) }
        }
    }

    var statusText: String {
        switch state {
        case .starting: "Starting…"
        case .armed: micActive ? "Armed · system + mic" : "Armed · system audio"
        case .saving: "Saving replay…"
        case .paused: pauseReason == .manual ? "Paused" : "Paused · streaming app open"
        case .needsScreenPermission: "Screen Recording permission needed"
        case .error(let message): "Error: \(message)"
        }
    }

    var isArmed: Bool { state == .armed }
    var canSave: Bool { state == .armed }
    var isPaused: Bool { pauseReason != nil }

    // MARK: - Lifecycle

    func start() {
        // If a protected app is already frontmost at launch, come up paused (don't capture).
        if shouldAutoPause(forFrontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            pauseReason = .autoProtected
            state = .paused
            return
        }
        Task { await startEngine() }
    }

    private func startEngine() async {
        guard recorder == nil, pauseReason == nil else { return }
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
            recorder.onCaptureFailure = { [weak self] in
                Task { @MainActor in self?.handleCaptureFailure() }
            }
            try await recorder.start()

            // A pause may have arrived while the stream was starting up — honor it.
            if pauseReason != nil {
                await recorder.stop()
                return
            }

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
        guard recorder != nil,
              previous.captureSignature != settings.captureSignature,
              !isRestarting
        else { return }
        isRestarting = true
        defer { isRestarting = false }
        await stop()
        await startEngine()
    }

    // MARK: - Recovery

    private func handleCaptureFailure() {
        requestRestart(reason: "capture interrupted")
    }

    private func handleDisplayChange() {
        // Debounce bursts of screen-parameter changes into a single restart.
        displayChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestRestart(reason: "display changed") }
        displayChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Restart capture — unless a save is in flight, in which case restart once it finishes.
    private func requestRestart(reason: String) {
        guard recorder != nil, pauseReason == nil else { return } // not armed / paused → nothing to recover
        if state == .saving {
            pendingRestart = true
            return
        }
        guard !isRestarting else { return }
        Task { await performRestart() }
    }

    private func performRestart() async {
        guard !isRestarting else { return }
        isRestarting = true
        defer { isRestarting = false }

        // Crash-loop guard: cap restarts in a window, then pause and retry once after a cooldown.
        let now = Date()
        restartTimestamps = restartTimestamps.filter { now.timeIntervalSince($0) < 30 }
        guard restartTimestamps.count < 3 else {
            await stop()
            state = .error("Capture keeps failing — paused, retrying shortly.")
            Task {
                try? await Task.sleep(for: .seconds(15))
                self.restartTimestamps.removeAll()
                if self.recorder == nil { await self.startEngine() }
            }
            return
        }
        restartTimestamps.append(now)

        guard Permissions.screenRecordingGranted() else {
            await stop()
            state = .needsScreenPermission
            return
        }
        await stop()
        await startEngine()
    }

    // MARK: - Pause (Smart Pause)

    /// Manual pause/resume (menu + hotkey). A manual pause "sticks" until manually resumed.
    func togglePause() {
        if pauseReason != nil { resume(trigger: .manual) }
        else { pause(reason: .manual) }
    }

    private func pause(reason: PauseReason) {
        autoResumeWork?.cancel()
        if let current = pauseReason {
            // Already paused; upgrade an auto-pause to manual so app-switching won't resume it.
            if reason == .manual, current != .manual { pauseReason = .manual }
            return
        }
        // Don't tear down mid-save; apply once the save finishes.
        if state == .saving { pendingPause = reason; return }
        pauseReason = reason
        state = .paused
        Task { await stop() } // tears down the SCStream → recording indicator clears → DRM plays
    }

    private func resume(trigger: PauseReason) {
        guard let reason = pauseReason else { return }
        // Auto-resume must never override a deliberate manual pause.
        if trigger == .autoProtected, reason == .manual { return }
        autoResumeWork?.cancel()
        pauseReason = nil
        Task { await startEngine() }
    }

    private func handleFrontmostChange(_ bundleID: String?) {
        guard settings.autoPauseForProtectedApps else { return }
        if shouldAutoPause(forFrontmost: bundleID) {
            pause(reason: .autoProtected) // immediate, so protected video unblocks fast
        } else {
            scheduleAutoResume() // debounced, to avoid churn while alt-tabbing
        }
    }

    private func shouldAutoPause(forFrontmost bundleID: String?) -> Bool {
        guard settings.autoPauseForProtectedApps, let bundleID else { return false }
        return settings.protectedApps.contains { $0.bundleID == bundleID }
    }

    private func scheduleAutoResume() {
        guard pauseReason == .autoProtected else { return }
        autoResumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resume(trigger: .autoProtected) }
        autoResumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
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
                self.state = .armed
            } catch {
                self.state = .error("save failed: \(error)")
            }
            // A pause requested mid-save takes priority over a deferred restart.
            if let reason = self.pendingPause {
                self.pendingPause = nil
                self.pause(reason: reason)
            } else if self.pendingRestart {
                self.pendingRestart = false
                self.requestRestart(reason: "deferred after save")
            }
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

    // MARK: - Shortcut

    /// Re-read the active shortcuts into their labels. Called at launch and from the Settings
    /// recorders' `onChange`, so the menu's shortcut suffixes update immediately (no relaunch).
    func refreshShortcutLabels() {
        saveShortcutLabel = KeyboardShortcuts.getShortcut(for: .saveReplay).map { "\($0)" } ?? ""
        pauseShortcutLabel = KeyboardShortcuts.getShortcut(for: .togglePause).map { "\($0)" } ?? ""
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
