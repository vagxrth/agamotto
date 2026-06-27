import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var controller = ReplayController.shared

    private let resolutions = [360, 480, 720, 1080]
    private let fpsOptions = [30, 60]
    private let replayOptions = [15, 30, 60, 90, 120]
    private let bufferOptions = [120, 300, 600]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agamotto").font(.headline)
                        Text("Instant replay for your screen")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(Self.versionString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("Video") {
                Picker("Resolution", selection: $controller.settings.resolution) {
                    ForEach(resolutions, id: \.self) { Text("\($0)p").tag($0) }
                }
                Picker("Frame rate", selection: $controller.settings.fps) {
                    ForEach(fpsOptions, id: \.self) { Text("\($0) fps").tag($0) }
                }
            }

            Section("Replay") {
                Picker("Replay length", selection: $controller.settings.replaySeconds) {
                    ForEach(replayOptions, id: \.self) { Text(durationLabel($0)).tag($0) }
                }
                Picker("Buffer length", selection: $controller.settings.bufferSeconds) {
                    ForEach(bufferOptions, id: \.self) { Text(durationLabel($0)).tag($0) }
                }
            }

            Section("Audio") {
                Toggle("Include microphone", isOn: $controller.settings.includeMicrophone)
                if controller.settings.includeMicrophone {
                    HStack {
                        Text("Mic gain")
                        Slider(value: $controller.settings.micGainDb, in: 0...18, step: 1)
                        Text("\(Int(controller.settings.micGainDb)) dB")
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }

            Section("Output") {
                HStack {
                    Text(controller.settings.outputDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…", action: chooseOutputFolder)
                }
            }

            Section {
                Toggle("Auto-pause for streaming apps", isOn: $controller.settings.autoPauseForProtectedApps)
                if controller.settings.autoPauseForProtectedApps {
                    ForEach(controller.settings.protectedApps) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Button {
                                controller.settings.protectedApps.removeAll { $0.bundleID == app.bundleID }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Menu("Add App…") {
                        let apps = runningApps
                        if apps.isEmpty {
                            Text("No other apps running")
                        } else {
                            ForEach(apps) { app in
                                Button(app.name) { controller.settings.protectedApps.append(app) }
                            }
                        }
                    }
                }
            } header: {
                Text("Protected playback")
            } footer: {
                Text("macOS blacks out DRM video (Netflix, Apple TV, Disney+, …) whenever the screen is being captured. Agamotto pauses while these apps are frontmost so they play, then resumes. For in-browser streaming, use the pause shortcut.")
            }

            Section {
                KeyboardShortcuts.Recorder("Save replay", name: .saveReplay) { _ in
                    controller.refreshShortcutLabels()
                }
                KeyboardShortcuts.Recorder("Pause / resume capture", name: .togglePause) { _ in
                    controller.refreshShortcutLabels()
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Changing resolution, frame rate, microphone, or buffer length briefly restarts capture.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    /// Currently-running regular apps (excluding Agamotto and already-listed ones), for the
    /// "Add App…" picker so the user can mark their streaming apps without typing bundle IDs.
    private var runningApps: [ProtectedApp] {
        let added = Set(controller.settings.protectedApps.map(\.bundleID))
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> ProtectedApp? in
                guard let id = app.bundleIdentifier,
                      id != Bundle.main.bundleIdentifier,
                      !added.contains(id),
                      seen.insert(id).inserted
                else { return nil }
                return ProtectedApp(bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    private func durationLabel(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds)s"
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            controller.settings.outputDirectoryPath = url.path
        }
    }
}
