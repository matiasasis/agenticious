import AppKit
import SwiftUI

/// Click, then press the shortcut. Esc cancels.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    @EnvironmentObject private var hotkeys: SummonHotkeys
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 10) {
            Button(monitor != nil ? "Press a shortcut…" : hotkey?.display ?? "Record shortcut") { monitor == nil ? record() : stop() }
                .buttonStyle(AgenticiousButtonStyle(isPrimary: monitor != nil, isCompact: true))
                .accessibilityLabel("Shortcut")
                .accessibilityValue(monitor != nil ? "Recording. Press a shortcut, or Escape to cancel." : hotkey?.display ?? "None")
            if hotkey != nil, monitor == nil {
                Button("Remove shortcut", systemImage: "xmark.circle") { hotkey = nil; hint = nil }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            if let hint { Text(hint).scaledFont(.caption).foregroundStyle(.orange) }
        }
        .onDisappear(perform: stop)
        // Shortcuts are off while recording; switching apps mid-recording must not leave them off.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    /// Every key press is swallowed meanwhile, so ⌘↩ or Esc can't save or close the editor mid-recording.
    private func record() {
        hint = nil
        hotkeys.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            // With ⌘ held, Cyrillic, Greek, Hebrew and Dvorak – QWERTY ⌘ layouts switch to Latin: name the key as
            // menus do, so ⌘C is recognised as ⌘C there too.
            let layer: NSEvent.ModifierFlags = flags.contains(.command) ? .command : []
            if event.keyCode == 53, flags.isEmpty {
                finish()
            } else if let pressed = Hotkey(keyCode: event.keyCode, flags: flags,
                                           characters: event.characters(byApplyingModifiers: layer) ?? event.charactersIgnoringModifiers) {
                if let problem = pressed.problem {
                    hint = problem
                } else {
                    hotkey = pressed
                    finish()
                }
            } else {
                hint = "That key can't be used. Try another."
            }
            return nil
        }
    }

    /// A key press ended the recording. Held past the repeat delay it keeps sending key-downs, and those must not
    /// reach the editor either: a held Esc would close it.
    private func finish() {
        hint = nil
        stop()
        var tail: Any?
        tail = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if event.type == .keyDown, event.isARepeat { return nil }
            tail.map(NSEvent.removeMonitor)
            tail = nil
            return event
        }
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        hotkeys.isRecording = false
    }
}
