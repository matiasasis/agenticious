import AppKit
import SwiftUI

/// The app-wide text size. macOS SwiftUI ignores Dynamic Type, so the app multiplies its fonts by this factor itself.
enum TextScale {
    /// A plain defaults key, so `-textScale 1.5` on the command line overrides it for one run without saving,
    /// until a size is chosen in the app (see `store`).
    static let key = "textScale"
    static let steps = [1.0, 1.1, 1.2, 1.3, 1.4, 1.5]
    static let range = 1.0...1.5

    /// Whatever is stored, kept within the range; a value that isn't a number is the normal size.
    static func clamped(_ value: Double) -> Double {
        value.isNaN ? 1 : min(max(value, range.lowerBound), range.upperBound)
    }

    /// The next step up, or the largest. From a size between two steps that is the step just above it.
    static func bigger(than value: Double) -> Double {
        steps.first { $0 > clamped(value) + 0.001 } ?? range.upperBound
    }

    static func smaller(than value: Double) -> Double {
        steps.last { $0 < clamped(value) - 0.001 } ?? range.lowerBound
    }

    static func nearestStep(to value: Double) -> Double {
        steps.min { abs($0 - value) < abs($1 - value) } ?? 1
    }

    /// `-textScale` on the command line outranks the saved value for the whole run, so a size chosen in the app would
    /// be saved but never shown. The first choice drops the argument, and the app's own setting takes over.
    static func store(_ value: Double, in defaults: UserDefaults = .standard) {
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if arguments.removeValue(forKey: key) != nil { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        defaults.set(value, forKey: key)
    }

    static func label(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    /// AppKit's buttons, pop-up menus and segmented controls keep their height whatever font their label has,
    /// so their bezels grow in the steps AppKit offers. At the normal size this is the default.
    static func controlSize(_ scale: Double) -> ControlSize {
        scale >= 1.4 ? .extraLarge : scale >= 1.2 ? .large : .regular
    }

    /// ⌘+ is ⌘⇧= on most keyboards, and people press ⌘= as browsers let them. A menu item answers one key only,
    /// so the plain press is retyped as the one the View menu has.
    static func commandPlus(for event: NSEvent) -> NSEvent {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              event.charactersIgnoringModifiers == "=" else { return event }
        return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, characters: "+",
                                charactersIgnoringModifiers: "+", isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }

    @MainActor
    static func acceptCommandEquals() {
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: commandPlus)
    }
}

extension EnvironmentValues {
    /// The factor every font is multiplied by; 1 outside a view tree that `textScaled()` covers.
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension View {
    /// Applies the stored text size to everything below, live. For the root of each window the app builds itself;
    /// sheets and popovers inherit it from the view that presents them.
    func textScaled() -> some View { modifier(TextScaleRoot()) }
}

private struct TextScaleRoot: ViewModifier {
    @AppStorage(TextScale.key) private var stored = 1.0

    func body(content: Content) -> some View {
        let scale = TextScale.clamped(stored)
        content
            .environment(\.textScale, scale)
            // Text with no font of its own. Left alone at the normal size, where the default is already right.
            .font(scale == 1 ? nil : ScaledFont.body.font(scale))
            .controlSize(TextScale.controlSize(scale))
    }
}

/// The View menu's text size commands, with the shortcuts browsers use.
struct TextSizeCommands: Commands {
    @AppStorage(TextScale.key) private var stored = 1.0

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Make Text Bigger") { TextScale.store(TextScale.bigger(than: stored)) }
                .keyboardShortcut("+")
                .disabled(TextScale.clamped(stored) == TextScale.range.upperBound)
            Button("Make Text Smaller") { TextScale.store(TextScale.smaller(than: stored)) }
                .keyboardShortcut("-")
                .disabled(TextScale.clamped(stored) == TextScale.range.lowerBound)
            Button("Actual Size") { TextScale.store(1) }
                .keyboardShortcut("0")
                .disabled(TextScale.clamped(stored) == 1)
        }
    }
}
