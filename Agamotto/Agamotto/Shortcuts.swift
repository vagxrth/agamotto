import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global "save the last N seconds" shortcut. Defaults to ⌃⌥R; user-rebindable in Settings.
    static let saveReplay = Self("saveReplay", default: .init(.r, modifiers: [.control, .option]))

    /// Global "pause / resume capture" shortcut. Defaults to ⌃⌥P; user-rebindable in Settings.
    /// Handy before watching DRM video in a browser, where auto-pause can't detect it.
    static let togglePause = Self("togglePause", default: .init(.p, modifiers: [.control, .option]))
}
