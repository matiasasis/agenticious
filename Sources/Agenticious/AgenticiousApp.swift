import AppKit
import SwiftUI

@main
struct AgenticiousApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()

    init() {
        Self.importUnbundledSettings()
        Self.importSettingsFromAgentDeck()
    }

    private static func importUnbundledSettings() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier == "com.agenticious.app",
              !defaults.bool(forKey: "importedUnbundledSettings") else { return }
        for (key, value) in defaults.persistentDomain(forName: "Agenticious") ?? [:] {
            if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "importedUnbundledSettings")
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
                .environmentObject(store.notifications)
                .environmentObject(store.usage)
                .environmentObject(store.diagnostics)
                .environmentObject(store.presets)
                .environmentObject(store.skillLocations)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1400, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Summon agent") { store.composer = Composer(project: store.composerProject) }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.selection = .settings }
                    .keyboardShortcut(",")
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(store.usage)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: AgenticiousMenuIcon.image)
                if store.attentionCount > 0 { Text("\(store.attentionCount)") }
            }
            .modifier(NotificationNavigation(store: store, notifications: store.notifications))
            .accessibilityLabel("Agenticious, \(store.attentionCount) agents need attention")
        }
        .menuBarExtraStyle(.window)
    }
}

/// `swift run` produces a bare executable, not an .app bundle; this makes it behave like a regular foreground app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = Bundle.module.url(forResource: "BundleIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct NotificationNavigation: ViewModifier {
    let store: SessionStore
    @ObservedObject var notifications: AgentNotifications
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onReceive(notifications.$requestedSession) { id in
            guard let id else { return }
            Task { @MainActor in
                if store.session(id) != nil { store.selection = .session(id) }
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                notifications.requestedSession = nil
            }
        }
    }
}
