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
            Image(systemName: menuBarSymbol)
        }

        Settings {
            SettingsView()
        }
    }

    private var menuBarSymbol: String {
        switch controller.state {
        case .saving: "clock.badge.checkmark"
        case .armed: "clock.arrow.circlepath"
        case .paused: "pause.circle"
        case .needsScreenPermission, .error: "exclamationmark.triangle"
        case .starting: "clock"
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
