import AppKit
import SwiftUI

struct DashboardWindow: NSViewRepresentable {
    let visibilityChanged: (Bool) -> Void

    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.attached = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }

    func updateNSView(_ view: WindowProbe, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(visibilityChanged: visibilityChanged) }

    static func dismantleNSView(_ view: WindowProbe, coordinator: Coordinator) {
        coordinator.detach()
    }

    static func fitToDisplay() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "companion-dashboard" }),
              let screen = window.screen else { return }
        window.setFrame(screen.visibleFrame, display: true, animate: true)
    }

    static func restoredFrame(_ frame: CGRect, screens: [CGRect], fallback: CGRect) -> CGRect {
        guard let screen = screens.max(by: { intersectionArea(frame, $0) < intersectionArea(frame, $1) }),
              intersectionArea(frame, screen) > 0 else { return fallback }
        let width = min(frame.width, screen.width)
        let height = min(frame.height, screen.height)
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height), width: width, height: height)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    final class WindowProbe: NSView {
        var attached: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attached?(window) }
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private let visibilityChanged: (Bool) -> Void

        init(visibilityChanged: @escaping (Bool) -> Void) { self.visibilityChanged = visibilityChanged }

        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            window.identifier = NSUserInterfaceItemIdentifier("companion-dashboard")
            let restored = window.setFrameUsingName("CompanionDashboard")
            window.setFrameAutosaveName("CompanionDashboard")
            if !restored, let screen = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains("xeneon") }) {
                window.setFrame(screen.visibleFrame, display: false)
            }
            recoverFrame()
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.reportVisibility() }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.visibilityChanged(false) }
            })
            observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recoverFrame() }
            })
            Task { @MainActor [weak self] in self?.reportVisibility() }
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            window = nil
            Task { @MainActor in visibilityChanged(false) }
        }

        private func reportVisibility() {
            visibilityChanged(window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false)
        }

        private func recoverFrame() {
            guard let window, let fallback = NSScreen.main?.visibleFrame else { return }
            let frame = DashboardWindow.restoredFrame(window.frame, screens: NSScreen.screens.map(\.visibleFrame), fallback: fallback)
            if window.frame != frame { window.setFrame(frame, display: true) }
        }
    }
}
