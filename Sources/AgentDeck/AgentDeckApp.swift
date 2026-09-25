import AppKit
import SwiftUI

@main
struct AgentDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()
    @StateObject private var usage = UsageMonitor()

    var body: some Scene {
        Window("AgentDeck", id: "dashboard") {
            DashboardView()
                .environmentObject(store)
                .environmentObject(usage)
                .frame(minWidth: 720, minHeight: 480)
        }

        WindowGroup("Agent", for: UUID.self) { $sessionID in
            if let sessionID, let session = store.session(sessionID) {
                SessionDetailView(session: session)
                    .environmentObject(store)
            } else {
                ContentUnavailableView("Session closed", systemImage: "xmark.circle")
            }
        }
        .defaultSize(width: 1100, height: 760)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(store)
        } label: {
            Label("\(store.attentionCount)", systemImage: store.attentionCount > 0 ? "hand.raised.fill" : "square.grid.2x2")
        }
    }
}

/// `swift run` produces a bare executable, not an .app bundle; this makes it behave like a regular foreground app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
