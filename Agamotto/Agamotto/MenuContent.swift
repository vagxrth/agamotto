import SwiftUI

/// The menu shown from the status-bar item.
struct MenuContent: View {
    @ObservedObject private var controller = ReplayController.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(controller.statusText)

        Divider()

        Button("Save Replay  ⌃⌥R") {
            controller.saveReplay()
        }
        .disabled(!controller.canSave)

        if controller.lastClipURL != nil {
            Button("Reveal Last Clip in Finder") { controller.revealLastClip() }
        }
        Button("Open Clips Folder") { controller.openClipsFolder() }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        if controller.state == .needsScreenPermission {
            Divider()
            Button("Grant Screen Recording…") { controller.grantScreenRecording() }
        }

        Divider()

        Button("Quit Agamotto") { NSApplication.shared.terminate(nil) }
    }
}
