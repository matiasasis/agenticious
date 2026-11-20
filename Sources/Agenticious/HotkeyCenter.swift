import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts through Carbon's hot keys. Unlike an NSEvent global monitor they need no Accessibility
/// permission, and the key press is taken instead of also reaching the app in front.
@MainActor
final class HotkeyCenter {
    var onPress: (Hotkey) -> Void = { _ in }
    private var handler: EventHandlerRef?
    private var registered: [UInt32: (hotkey: Hotkey, reference: EventHotKeyRef)] = [:]
    private var lastID: UInt32 = 0

    /// Replaces everything registered, and returns the shortcuts macOS refused. Exclusive, so a second running copy
    /// of the app (a dev build beside the installed one) is refused instead of opening a second window on the same
    /// press. A shortcut another app took the ordinary way still registers fine here.
    @discardableResult
    func register(_ hotkeys: [Hotkey]) -> [Hotkey] {
        unregisterAll()
        guard !hotkeys.isEmpty, installHandler() else { return hotkeys }
        return hotkeys.filter { hotkey in
            lastID += 1
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, EventHotKeyID(signature: hotkeySignature, id: lastID),
                                             GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            guard status == noErr, let reference else { return true }
            registered[lastID] = (hotkey, reference)
            return false
        }
    }

    func unregisterAll() {
        registered.values.forEach { UnregisterEventHotKey($0.reference) }
        registered = [:]
    }

    fileprivate func pressed(_ id: UInt32) {
        if let hotkey = registered[id]?.hotkey { onPress(hotkey) }
    }

    /// One handler for every shortcut, installed with the first, so a store that has none never touches Carbon.
    private func installHandler() -> Bool {
        guard handler == nil else { return true }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetEventDispatcherTarget(), hotkeyPressed, 1, &pressed,
                                   Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr
    }
}

private let hotkeySignature: OSType = 0x4147_4E54 // "AGNT"

/// A C callback can't capture, so the center arrives as the handler's user data; it lives as long as the app.
private let hotkeyPressed: EventHandlerUPP = { _, event, userData in
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == hotkeySignature, let userData else { return OSStatus(eventNotHandledErr) }
    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    let pressed = id.id
    // On the next turn of the main loop: no assumption about Carbon's thread, and no window opened from inside its dispatch.
    DispatchQueue.main.async { center.pressed(pressed) }
    return noErr
}
