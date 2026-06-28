import AppKit
import KeyboardShortcuts
import SwiftUI

@main
struct AgamottoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = ReplayController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            menuBarLabel
        }

        Settings {
            SettingsView()
        }
    }

    /// Menu bar icon: the Eye of Agamotto template glyph — bright while capturing, and a
    /// pre-dimmed template while paused (mirroring Apple's Focus on/off look). The dim is
    /// baked into the asset's alpha because `.opacity()` is ignored on a menu bar template.
    /// States that need attention fall back to a warning triangle so they stand out.
    @ViewBuilder private var menuBarLabel: some View {
        switch controller.state {
        case .needsScreenPermission, .error:
            Image(systemName: "exclamationmark.triangle")
        case .paused:
            Image("MenuBarEyeDim")
        default:
            Image("MenuBarEye")
        }
    }
}

/// Owns app lifecycle: starts the always-armed engine on launch, registers the global
/// save hotkey, and stops the engine cleanly on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if another Agamotto is already capturing, defer to it.
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }

        ReplayController.shared.start()

        // Global save shortcut (default ⌃⌥R, rebindable in Settings). No Accessibility prompt —
        // KeyboardShortcuts registers a Carbon hotkey under the hood.
        KeyboardShortcuts.onKeyDown(for: .saveReplay) {
            Task { @MainActor in ReplayController.shared.saveReplay() }
        }

        // Pause/resume capture (default ⌃⌥P) — e.g. before watching DRM video in a browser.
        KeyboardShortcuts.onKeyDown(for: .togglePause) {
            Task { @MainActor in ReplayController.shared.togglePause() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stop the capture stream cleanly before exiting (avoids a lingering recording indicator).
        Task { @MainActor in
            await ReplayController.shared.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != myPID }
    }
}
