import SwiftUI

/// The menu shown from the status-bar item.
struct MenuContent: View {
    @ObservedObject private var controller = ReplayController.shared
    @Environment(\.openSettings) private var openSettings

    private var saveShortcutSuffix: String {
        controller.saveShortcutLabel.isEmpty ? "" : "  \(controller.saveShortcutLabel)"
    }

    private var pauseShortcutSuffix: String {
        controller.pauseShortcutLabel.isEmpty ? "" : "  \(controller.pauseShortcutLabel)"
    }

    var body: some View {
        Text(controller.statusText)

        Divider()

        saveButton

        pauseButton

        if controller.lastClipURL != nil {
            Button("Reveal Last Clip in Finder") { controller.revealLastClip() }
        }
        Button("Open Clips Folder") { controller.openClipsFolder() }

        Divider()

        Button("Settings") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        if controller.state == .needsScreenPermission {
            Divider()
            Button("Grant Screen Recording…") { controller.grantScreenRecording() }
        }

        Divider()

        Button("Quit Agamotto") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    // Save / Pause use the native `.keyboardShortcut` so the hint is right-aligned and dimmed
    // (like Quit's ⌘Q), reflecting the user's current binding. Keys we can't express as a
    // Character (F-keys, arrows, …) fall back to showing the shortcut inline in the title.
    @ViewBuilder private var saveButton: some View {
        if let (key, mods) = Self.menuShortcut(for: controller.saveShortcutLabel) {
            Button("Save Replay") { controller.saveReplay() }
                .keyboardShortcut(key, modifiers: mods)
                .disabled(!controller.canSave)
        } else {
            Button("Save Replay\(saveShortcutSuffix)") { controller.saveReplay() }
                .disabled(!controller.canSave)
        }
    }

    @ViewBuilder private var pauseButton: some View {
        let title = controller.isPaused ? "Resume Capture" : "Pause Capture"
        if let (key, mods) = Self.menuShortcut(for: controller.pauseShortcutLabel) {
            Button(title) { controller.togglePause() }
                .keyboardShortcut(key, modifiers: mods)
        } else {
            Button("\(title)\(pauseShortcutSuffix)") { controller.togglePause() }
        }
    }

    /// Parse a display label like "⌃⌥R" into a SwiftUI key + modifiers for a native menu shortcut.
    private static func menuShortcut(for label: String) -> (KeyEquivalent, EventModifiers)? {
        guard let last = label.last, last.isASCII, last.isLetter || last.isNumber else { return nil }
        var mods: EventModifiers = []
        if label.contains("⌘") { mods.insert(.command) }
        if label.contains("⌥") { mods.insert(.option) }
        if label.contains("⌃") { mods.insert(.control) }
        if label.contains("⇧") { mods.insert(.shift) }
        return (KeyEquivalent(Character(last.lowercased())), mods)
    }
}
