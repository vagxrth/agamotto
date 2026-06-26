import Carbon.HIToolbox
import Foundation

/// A process-wide hotkey via Carbon's `RegisterEventHotKey`. Works whether or not the app
/// is focused and — unlike `CGEventTap`/`NSEvent` monitors — needs no Accessibility grant.
/// The handler fires on the main thread.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let handler: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // No captures → convertible to a C function pointer; self is passed via userData.
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            hotKey.handler()
            return noErr
        }
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x41474D54 /* "AGMT" */), id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}
