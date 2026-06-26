import SwiftUI

/// The menu shown from the status-bar item.
struct MenuContent: View {
    @ObservedObject private var controller = ReplayController.shared

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

        if controller.state == .needsScreenPermission {
            Divider()
            Button("Grant Screen Recording…") { controller.grantScreenRecording() }
        }

        Divider()

        Button("Quit Agamotto") { NSApplication.shared.terminate(nil) }
    }
}
