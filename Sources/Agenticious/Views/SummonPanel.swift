import AppKit
import SwiftUI

/// The Summon sheet in a window of its own, floating over whatever app is in front. A non-activating panel takes
/// the keyboard without making Agenticious the active app, so the main window stays where it is and closing the
/// panel hands the keyboard straight back.
final class SummonPanel: NSPanel {
    var onCancel: () -> Void = {}

    init() {
        // Non-activating has to be in the style mask from the start; added later it never reaches the window server.
        super.init(contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
        title = "Summon agent" // names the `--snapshot-dir` file
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { standardWindowButton($0)?.isHidden = true }
        isFloatingPanel = true
        // Panels hide while their app isn't active, which is the whole time this one is in use.
        hidesOnDeactivate = false
        canHide = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = NSColor(AgenticiousStyle.ink)
    }

    override var canBecomeKey: Bool { true }
    /// The folder picker and the skills sheet need Agenticious active, and activating brings its key and main
    /// windows forward. Being both keeps the real main window where it was.
    override var canBecomeMain: Bool { true }

    /// Esc, when no button in the sheet claimed it.
    override func cancelOperation(_ sender: Any?) { onCancel() }

    /// While another app is in front the menu bar isn't ours, so nothing would turn ⌘V into a paste. The panel
    /// settles every ⌘ key itself, which also keeps ⌘Q and ⌘N away from menus the user can't see.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only for keys typed into this window, not ones AppKit offers around while a sheet or popover has the keyboard.
        guard event.type == .keyDown, event.window === self else { return false }
        if super.performKeyEquivalent(with: event) { return true } // the sheet's own ⌘↩ and Esc buttons
        // The layout's ⌘ layer, as menus match it: Russian, Greek, Hebrew and Dvorak – QWERTY ⌘ give Latin letters only there.
        let characters = event.characters(byApplyingModifiers: .command) ?? event.charactersIgnoringModifiers
        switch SummonKey(characters: characters, flags: event.modifierFlags) {
        case let .edit(command): command.perform(on: firstResponder, sender: self)
        case .cancel: onCancel()
        case .swallow: break
        case .pass: return false
        }
        return true
    }
}

/// What the panel does with a key press that nothing inside it claimed.
enum SummonKey: Equatable {
    case edit(SummonEditCommand), cancel, swallow, pass

    init(characters: String?, flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection([.command, .shift, .option, .control])
        let character = characters?.unicodeScalars.first?.value
        if !flags.contains(.command) {
            self = .pass
        } else if let command = SummonEditCommand(characters: characters, flags: flags) {
            self = .edit(command)
        } else if flags == .command, characters?.lowercased() == "w" {
            self = .cancel
        } else if flags == [.command, .control], characters == " " {
            // Emoji & Symbols: a hidden Edit-menu item answers it, as it does in the sheet.
            self = .pass
        } else if character.map({ $0 < 0x20 || $0 == 0x7F || (0xF700...0xF8FF).contains($0) }) ?? true {
            // ⌘ with an arrow or delete is text editing, not a menu command; the text view gets it as a key press.
            self = .pass
        } else {
            self = .swallow
        }
    }
}

/// The Edit menu's shortcuts, run on whatever has the keyboard in the panel.
enum SummonEditCommand: Equatable {
    case cut, copy, paste, selectAll, undo, redo

    init?(characters: String?, flags: NSEvent.ModifierFlags) {
        switch (characters?.lowercased(), flags.intersection([.command, .shift, .option, .control])) {
        case ("x", .command): self = .cut
        case ("c", .command): self = .copy
        case ("v", .command): self = .paste
        case ("a", .command): self = .selectAll
        case ("z", .command): self = .undo
        case ("z", [.command, .shift]): self = .redo
        default: return nil
        }
    }

    @MainActor
    func perform(on responder: NSResponder?, sender: Any?) {
        switch self {
        case .cut: responder?.tryToPerform(#selector(NSText.cut(_:)), with: sender)
        case .copy: responder?.tryToPerform(#selector(NSText.copy(_:)), with: sender)
        case .paste: responder?.tryToPerform(#selector(NSText.paste(_:)), with: sender)
        case .selectAll: responder?.tryToPerform(#selector(NSResponder.selectAll(_:)), with: sender)
        case .undo: if responder?.undoManager?.canUndo == true { responder?.undoManager?.undo() }
        case .redo: if responder?.undoManager?.canRedo == true { responder?.undoManager?.redo() }
        }
    }
}
