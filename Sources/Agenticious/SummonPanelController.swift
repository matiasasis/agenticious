import AppKit
import Combine
import SwiftUI

/// What the floating window gives the sheet that `.sheet` otherwise would: a way to close, and the screen to fit.
struct SummonWindowHost {
    /// Weak: the window holds the sheet, which holds this.
    weak var window: NSWindow?
    let visibleFrame: CGRect
    /// A shortcut pressed while the window is open switches the task and keeps what's typed.
    let presetRequests = PassthroughSubject<String, Never>()
    /// Whether the main window should turn to the agent that was just started, as it does for the sheet.
    let showsNewAgent: () -> Bool
    let close: () -> Void
}

/// Shows the floating Summon window over the app in front, and gives the keyboard back when it closes.
@MainActor
final class SummonPanelController {
    /// The app the window took activation from for the folder picker; nil while it has borrowed nothing, so an
    /// activation the user made (⌘Tab, a click on the main window) is left alone when the window closes.
    fileprivate static var borrowedFrom: NSRunningApplication?

    private var panel: SummonPanel?
    private var host: SummonWindowHost?
    private var resigned: AnyCancellable?

    init() {
        // Once Agenticious is no longer active the borrowed activation is over; coming back later is the user's choice.
        resigned = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { _ in MainActor.assumeIsolated { Self.borrowedFrom = nil } }
    }

    /// Whether the window is being used from another app, which then keeps the user: the main window isn't to
    /// change under them. Used from Agenticious itself, it behaves like the sheet.
    private var isOverAnotherApp: Bool { !NSRunningApplication.current.isActive || Self.borrowedFrom != nil }

    /// False when the window couldn't be shown, so whoever asked can say so.
    @discardableResult
    func show(presetID: String, store: SessionStore) -> Bool {
        // A modal window (the folder picker, say) owns the keyboard until it's answered.
        guard NSApp.modalWindow == nil else {
            NSSound.beep()
            return false
        }
        if let panel, let host {
            // Pressed again while open: switch the task and stay where it is, so a window moved by hand stays put.
            host.presetRequests.send(presetID)
            present(panel)
            return true
        }
        Self.borrowedFrom = nil
        let target = SummonPlacement.target()
        let panel = SummonPanel()
        let host = SummonWindowHost(window: panel, visibleFrame: target.visible,
                                    showsNewAgent: { [weak self] in self?.isOverAnotherApp == false },
                                    close: { [weak self] in self?.close() })
        let sheet = NewTaskSheet(project: store.lastUsedProject, template: store.presets.preset(id: presetID), host: host)
        let hosting = NSHostingView(rootView: sheet.agenticiousEnvironment(store))
        // The sheet draws its own header under the hidden title bar, instead of leaving a strip for it.
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        panel.setFrame(SummonPlacement.frame(size: hosting.fittingSize, over: target.window, in: target.visible), display: false)
        panel.onCancel = { [weak self] in self?.close() }
        self.panel = panel
        self.host = host
        present(panel)
        return true
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        host = nil
        let borrowedFrom = Self.borrowedFrom
        Self.borrowedFrom = nil
        // Taking the views out ends the sheet, so its paste monitor goes with it. On the next turn, because Cancel
        // and Start call this from inside those views.
        DispatchQueue.main.async { panel.contentView = nil }
        // Usually the app in front never stopped being active, and has the keyboard again once the window is gone.
        // Not `NSApp.isActive`: that is also true while the window merely has the keyboard.
        guard NSRunningApplication.current.isActive, let borrowedFrom, !borrowedFrom.isTerminated else { return panel.orderOut(nil) }
        // The folder picker made Agenticious active. Ordering the key window out now would make the main window key
        // and bring it forward, so hand activation back first and order out once it has gone.
        panel.alphaValue = 0
        let resigned = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
        // Also the way out when macOS refuses the hand-back; ordering out twice does nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.removeObserver(resigned)
            panel.orderOut(nil)
        }
        NSApp.yieldActivation(to: borrowedFrom)
        borrowedFrom.activate()
    }

    /// Not `makeKeyAndOrderFront`: an app that isn't active may not put a window above the active app's.
    private func present(_ panel: SummonPanel) {
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeMain()
    }
}

extension NSApplication {
    /// The folder picker is an ordinary window: opened from the floating Summon window while another app is in
    /// front, it would sit behind that app with no keyboard. Activating without `.activateAllWindows` brings only
    /// the key and main windows forward, and the Summon window is both, so the main window stays behind.
    func activateForChildWindow() {
        // Not `isActive`: that is already true while the Summon window has the keyboard, though another app is in front.
        guard !NSRunningApplication.current.isActive else { return }
        SummonPanelController.borrowedFrom = NSWorkspace.shared.frontmostApplication
        NSRunningApplication.current.activate(options: [])
    }
}

/// Where a preset's shortcut opens the floating Summon window. Chosen in Customize → Preferences → General.
enum SummonPosition: String, CaseIterable, Identifiable {
    case mainDisplay, currentDisplay, currentWindow

    static let defaultsKey = "summonPosition"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mainDisplay: "Middle of the main display"
        case .currentDisplay: "Middle of the display in use"
        case .currentWindow: "Over the window in use"
        }
    }

    static var chosen: SummonPosition {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SummonPosition.init) ?? .mainDisplay
    }
}

enum SummonPlacement {
    /// Centred over `window`, or in the middle of the screen without one; never past the screen's edges.
    static func frame(size: CGSize, over window: CGRect? = nil, in visible: CGRect) -> CGRect {
        let size = CGSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
        let center = window.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: visible.midX, y: visible.midY)
        let x = min(max(center.x - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(center.y - size.height / 2, visible.minY), visible.maxY - size.height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// The screen to open on and, for `.currentWindow`, the window to centre over. The main display is the first
    /// screen, the one with the menu bar; the display in use is the one holding most of the front window, else the
    /// one under the pointer.
    static func target(_ position: SummonPosition, screens: [(frame: CGRect, visible: CGRect)], focusedWindow: CGRect?,
                       pointer: CGPoint) -> (visible: CGRect, window: CGRect?) {
        guard !screens.isEmpty else { return (CGRect(x: 0, y: 0, width: 1040, height: 950), nil) }
        guard position != .mainDisplay else { return (screens[0].visible, nil) }
        let screen = screens[Self.screen(frames: screens.map(\.frame), focusedWindow: focusedWindow, pointer: pointer)]
        return (screen.visible, position == .currentWindow ? focusedWindow : nil)
    }

    /// The screen holding most of the window being worked in; without one, the screen under the pointer.
    static func screen(frames: [CGRect], focusedWindow: CGRect?, pointer: CGPoint) -> Int {
        if let focusedWindow {
            let overlaps = frames.map { $0.intersection(focusedWindow) }.map { $0.isNull ? 0 : $0.width * $0.height }
            if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 { return best }
        }
        return frames.firstIndex { $0.contains(pointer) } ?? 0
    }

    /// Quartz measures from the top-left of the primary display; AppKit from its bottom-left.
    static func cocoaRect(quartz: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: quartz.minX, y: primaryHeight - quartz.maxY, width: quartz.width, height: quartz.height)
    }

    /// The frontmost app's front window, from the window list: `NSScreen.main` isn't a sure answer while another app
    /// has the keyboard. Window bounds, unlike titles and contents, need no Screen Recording permission.
    @MainActor
    static func focusedWindowFrame() -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]],
              let front = windows.first(where: { $0[kCGWindowOwnerPID] as? pid_t == pid && $0[kCGWindowLayer] as? Int == 0 }),
              let bounds = front[kCGWindowBounds] as? NSDictionary, let quartz = CGRect(dictionaryRepresentation: bounds)
        else { return nil }
        return cocoaRect(quartz: quartz, primaryHeight: primary.frame.height)
    }

    /// Where the window goes right now, by the chosen position. The front window is only looked up when it matters.
    @MainActor
    static func target(_ position: SummonPosition = .chosen) -> (visible: CGRect, window: CGRect?) {
        target(position, screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) },
               focusedWindow: position == .mainDisplay ? nil : focusedWindowFrame(), pointer: NSEvent.mouseLocation)
    }
}
