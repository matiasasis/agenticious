import AppKit
import SwiftUI

@main
struct AgenticiousApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()
    @StateObject private var usage = UsageMonitor()

    init() {
        Self.importSettingsFromAgentDeck()
    }

    /// The app was called AgentDeck, and a bare executable's defaults domain is its name, so settings saved
    /// before the rename live in AgentDeck.plist. Copy them over once so favorites survive.
    private static func importSettingsFromAgentDeck() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "importedAgentDeckSettings"), let old = UserDefaults(suiteName: "AgentDeck") else { return }
        for key in ["favoriteProjects", "lastAgent", "useWorktree"] where defaults.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "importedAgentDeckSettings")
    }

    var body: some Scene {
        Window("Agenticious", id: "main") {
            MainView()
                .environmentObject(store)
                .environmentObject(usage)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1400, height: 880)

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
