import AppKit
import UserNotifications

enum AgentAlert: String {
    case needsInput, completed, failed

    static func transition(from old: SessionStatus, to new: SessionStatus) -> AgentAlert? {
        switch new {
        case .needsYou, .yourTurn:
            if case .needsYou = old { return nil }
            if case .yourTurn = old { return nil }
            return .needsInput
        case .done:
            if case .done = old { return nil }
            return .completed
        case .exited(let code) where code != 0:
            if case .exited = old { return nil }
            return .failed
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .needsInput: return "Your agent needs you"
        case .completed: return "Mission complete"
        case .failed: return "Agent stopped unexpectedly"
        }
    }

    var sound: String {
        switch self {
        case .needsInput: return "Glass"
        case .completed: return "Hero"
        case .failed: return "Basso"
        }
    }
}

@MainActor
final class AgentNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var bannersEnabled: Bool { didSet { defaults.set(bannersEnabled, forKey: "notificationBanners") } }
    @Published var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: "notificationSounds") } }
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var error: String?
    @Published var requestedSession: UUID?
    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter?

    var available: Bool { center != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bannersEnabled = defaults.bool(forKey: "notificationBanners")
        soundsEnabled = defaults.object(forKey: "notificationSounds") as? Bool ?? true
        // UserNotifications crashes when invoked from an unbundled SwiftPM executable.
        center = Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
        super.init()
        center?.delegate = self
    }

    func refreshAuthorization() async {
        guard let center else { return }
        authorization = await center.notificationSettings().authorizationStatus
    }

    func enableNotifications() async {
        guard let center else { return }
        do {
            error = nil
            bannersEnabled = try await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorization()
        } catch { self.error = error.localizedDescription }
    }

    func notify(_ event: AgentAlert, sessionID: UUID, task: String) {
        Task {
            await refreshAuthorization()
            guard bannersEnabled, authorization == .authorized, let center else {
                playSound(event.sound)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = String(task.prefix(200))
            content.threadIdentifier = sessionID.uuidString
            content.userInfo = ["sessionID": sessionID.uuidString]
            if soundsEnabled { content.sound = UNNotificationSound(named: .init(rawValue: "\(event.sound).aiff")) }
            let request = UNNotificationRequest(identifier: "\(sessionID).\(event.rawValue)", content: content, trigger: nil)
            do { try await center.add(request) }
            catch { self.error = error.localizedDescription }
        }
    }

    func playSound(_ name: String) {
        guard soundsEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    func sendTest() {
        notify(.completed, sessionID: UUID(), task: "All connected. Your agents can reach you here.")
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["sessionID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            requestedSession = id
            completionHandler()
        }
    }
}
