import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global "save the last N seconds" shortcut. Defaults to ⌃⌥R; user-rebindable in Settings.
    static let saveReplay = Self("saveReplay", default: .init(.r, modifiers: [.control, .option]))
}
