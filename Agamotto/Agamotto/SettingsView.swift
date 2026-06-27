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
                KeyboardShortcuts.Recorder("Save replay shortcut", name: .saveReplay) { _ in
                    controller.refreshSaveShortcutLabel()
                }
            } footer: {
                Text("Changing resolution, frame rate, microphone, or buffer length briefly restarts capture.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
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
