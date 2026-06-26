import AppKit
import Carbon.HIToolbox
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
        case .needsScreenPermission, .error: "exclamationmark.triangle"
        case .starting: "clock"
        }
    }
}

/// Owns app lifecycle: starts the always-armed engine on launch, registers the global
/// save hotkey, and stops the engine cleanly on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var saveHotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if another Agamotto is already capturing, defer to it.
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }

        ReplayController.shared.start()

        // ⌃⌥R — global, works without focus and without an Accessibility prompt (Carbon).
        saveHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(controlKey | optionKey)
        ) {
            Task { @MainActor in ReplayController.shared.saveReplay() }
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
