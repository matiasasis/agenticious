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
        let display = SummonPlacement.mainDisplay
        let panel = SummonPanel()
        let host = SummonWindowHost(window: panel, visibleFrame: display,
                                    showsNewAgent: { [weak self] in self?.isOverAnotherApp == false },
                                    close: { [weak self] in self?.close() })
        let sheet = NewTaskSheet(project: store.lastUsedProject, template: store.presets.preset(id: presetID), host: host)
        let hosting = NSHostingView(rootView: sheet.agenticiousEnvironment(store))
        // The sheet draws its own header under the hidden title bar, instead of leaving a strip for it.
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        panel.setFrame(SummonPlacement.frame(size: hosting.fittingSize, in: display), display: false)
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

enum SummonPlacement {
    /// The middle of the screen, never past its edges.
    static func frame(size: CGSize, in visible: CGRect) -> CGRect {
        let size = CGSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
        return CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// The main display's usable area: the one with the menu bar, set in System Settings → Displays. It is where the
    /// window always opens, whichever app or display was in use.
    @MainActor
    static var mainDisplay: CGRect { NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1040, height: 950) }
}
