import AppKit
import Carbon.HIToolbox

/// A key and its modifiers, as recorded in a preset's editor and registered system-wide.
struct Hotkey: Codable, Hashable {
    /// In the order macOS draws them.
    enum Modifier: String, Codable, CaseIterable {
        case control, option, shift, command

        var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }

        var carbon: Int {
            switch self {
            case .control: controlKey
            case .option: optionKey
            case .shift: shiftKey
            case .command: cmdKey
            }
        }

        var flag: NSEvent.ModifierFlags {
            switch self {
            case .control: .control
            case .option: .option
            case .shift: .shift
            case .command: .command
            }
        }
    }

    /// The physical key, so the shortcut stays put when the keyboard layout changes.
    var keyCode: UInt32
    var modifiers: [Modifier]
    /// What the key was called when it was recorded, so showing the shortcut needs no layout lookup.
    var key: String

    var display: String { Modifier.allCases.filter(modifiers.contains).map(\.symbol).joined() + key }
    var carbonModifiers: UInt32 { Set(modifiers).reduce(0) { $0 | UInt32($1.carbon) } }

    /// Two shortcuts clash on the key and modifiers, whatever order or name the file gives them.
    func matches(_ other: Hotkey) -> Bool { keyCode == other.keyCode && carbonModifiers == other.carbonModifiers }

    /// Why this can't be a system-wide shortcut, or nil when it can.
    var problem: String? {
        let held = Set(modifiers)
        // A bare or shifted key would be taken away from typing in every app.
        if held.isDisjoint(with: [.command, .control, .option]), !Self.functionKeys.contains(Int(keyCode)) {
            return "Add ⌘, ⌃ or ⌥ to the shortcut."
        }
        // Taken system-wide these stop working everywhere, the Summon window included.
        if (held == [.command] && Self.standardKeys.contains(key)) || (held == [.command, .shift] && key == "Z") {
            return "\(display) is a standard shortcut. Choose another."
        }
        return nil
    }
}

extension Hotkey {
    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                       kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    /// With ⌘ alone: editing, and the commands nearly every app has.
    private static let standardKeys: Set<String> = ["A", "C", "V", "X", "Z", "Q", "W", "↩", "S", "N", "O", "P", "F", "H", "M", "T", ",", "Space", "⇥"]

    /// Keys that type nothing, or nothing worth showing.
    private static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ].merging(functionKeys.enumerated().map { ($1, "F\($0 + 1)") }) { name, _ in name }

    /// The shortcut a key press describes, or nil for a key with no name to show. `characters` are the key's own,
    /// without ⇧ or ⌥, so ⇧⌘1 is "1" and not "!"; with ⌘ held they are the layout's ⌘ layer, so ⌘C is "C" on a
    /// Russian keyboard too.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        // "ß" uppercases to "SS": keep the key's own character when uppercasing stops it being one.
        let upper = characters?.uppercased() ?? ""
        let typed = upper.count == 1 ? upper : characters ?? ""
        let isPrintable = typed.count == 1 && typed.unicodeScalars.allSatisfy {
            $0.value > 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
        }
        guard let key = Self.namedKeys[Int(keyCode)] ?? (isPrintable ? typed : nil) else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: Modifier.allCases.filter { flags.contains($0.flag) }, key: key)
    }
}

/// Which preset each shortcut opens, and why the others don't work.
struct HotkeyPlan: Equatable {
    struct Binding: Equatable {
        let hotkey: Hotkey
        let presetID: String
    }

    private(set) var bindings: [Binding] = []
    /// By preset id.
    private(set) var problems: [String: String] = [:]

    /// The first preset to claim a shortcut keeps it, in the saved order. A clash only costs the later preset its
    /// shortcut: it is not a reason to refuse the whole presets file.
    init(presets: [TaskTemplate]) {
        var owners: [(hotkey: Hotkey, name: String)] = []
        for preset in presets {
            guard let hotkey = preset.hotkey else { continue }
            if let problem = hotkey.problem {
                problems[preset.id] = problem
            } else if let owner = owners.first(where: { $0.hotkey.matches(hotkey) }) {
                problems[preset.id] = "\(owner.name) already uses \(hotkey.display)."
            } else {
                owners.append((hotkey, preset.name))
                bindings.append(Binding(hotkey: hotkey, presetID: preset.id))
            }
        }
    }

    /// The plan as it would be with `draft` saved. A newly recorded shortcut goes last, so a preset that already has
    /// it keeps it. An unchanged one is judged where the preset sits, so the editor agrees with the cards when a
    /// hand-edited file holds a clash.
    init(presets: [TaskTemplate], editing draft: TaskTemplate) {
        var all = presets
        if let index = all.firstIndex(where: { $0.id == draft.id }),
           let saved = all[index].hotkey, let hotkey = draft.hotkey, saved.matches(hotkey) {
            all[index] = draft
        } else {
            all.removeAll { $0.id == draft.id }
            all.append(draft)
        }
        self.init(presets: all)
    }
}
