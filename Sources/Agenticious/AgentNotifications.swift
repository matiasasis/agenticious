import AppKit
import UserNotifications

enum AgentAlert: String, CaseIterable {
    case needsYou, yourTurn, completed, ended, failed

    static func transition(from old: SessionStatus, to new: SessionStatus) -> AgentAlert? {
        switch new {
        case .needsYou, .yourTurn:
            if case .needsYou = old { return nil }
            if case .yourTurn = old { return nil }
            return new == .yourTurn ? .yourTurn : .needsYou
        case .done:
            if case .done = old { return nil }
            return .completed
        case .ended:
            if case .ended = old { return nil }
            return .ended
        case .exited(let code) where code != 0:
            if case .exited = old { return nil }
            return .failed
        default: return nil
        }
    }

    var summary: String {
        switch self {
        case .needsYou: return "Needs you"
        case .yourTurn: return "Finished its turn"
        case .completed: return "Mission complete"
        case .ended: return "Ended"
        case .failed: return "Stopped unexpectedly"
        }
    }

    /// One glanceable line: what happened, and to which agent. The details are a click away in the app.
    func message(task: String) -> String {
        let line = task.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let name = line.count > 60 ? line.prefix(59) + "…" : line
        return name.isEmpty ? summary : "\(summary) · \(name)"
    }

    var sound: String {
        switch self {
        case .needsYou, .yourTurn, .ended: return "Glass"
        case .completed: return "Hero"
        case .failed: return "Basso"
        }
    }

    /// Buttons on the banner, after the click that opens the agent.
    var actions: [AgentNotificationAction] {
        switch self {
        case .needsYou: return [.open]
        case .yourTurn: return [.reply, .open]
        case .completed, .ended: return [.archive, .open]
        case .failed: return [.resume, .open]
        }
    }
}

enum AgentNotificationAction: String {
    case open, reply, resume, archive

    var notificationAction: UNNotificationAction {
        switch self {
        case .open:
            return UNNotificationAction(identifier: rawValue, title: "Open", options: [.foreground])
        case .reply:
            return UNTextInputNotificationAction(identifier: rawValue, title: "Reply…", options: [],
                                                 textInputButtonTitle: "Send", textInputPlaceholder: "Message the agent")
        case .resume:
            return UNNotificationAction(identifier: rawValue, title: "Resume", options: [.foreground])
        case .archive:
            return UNNotificationAction(identifier: rawValue, title: "Archive", options: [.destructive])
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
    /// Runs Reply, Resume and Archive from a banner; the text is what was typed into Reply.
    var perform: (AgentNotificationAction, UUID, String?) -> Void = { _, _, _ in }
    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter?
    private let summonSound = Bundle.module.url(forResource: "Summon", withExtension: "wav")
        .flatMap { NSSound(contentsOf: $0, byReference: false) }

    var available: Bool { center != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bannersEnabled = defaults.bool(forKey: "notificationBanners")
        soundsEnabled = defaults.object(forKey: "notificationSounds") as? Bool ?? true
        // UserNotifications crashes when invoked from an unbundled SwiftPM executable.
        center = Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
        super.init()
        center?.delegate = self
        center?.setNotificationCategories(Set(AgentAlert.allCases.map { alert in
            UNNotificationCategory(identifier: alert.rawValue, actions: alert.actions.map(\.notificationAction), intentIdentifiers: [])
        }))
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

    func notify(_ event: AgentAlert, sessionID: UUID, message: String) {
        Task {
            await refreshAuthorization()
            guard bannersEnabled, authorization == .authorized, let center else {
                playSound(event.sound)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "AGENTICIOUS"
            content.body = message
            content.categoryIdentifier = event.rawValue
            content.threadIdentifier = sessionID.uuidString
            content.userInfo = ["sessionID": sessionID.uuidString]
            if soundsEnabled { content.sound = UNNotificationSound(named: .init(rawValue: "\(event.sound).aiff")) }
            let request = UNNotificationRequest(identifier: "\(sessionID).\(event.rawValue)", content: content, trigger: nil)
            do { try await center.add(request) }
            catch { self.error = error.localizedDescription }
        }
    }

    func playSummonSound() {
        guard soundsEnabled else { return }
        summonSound?.volume = 0.5
        summonSound?.play()
    }

    func playSound(_ name: String) {
        guard soundsEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    func sendTest() {
        notify(.completed, sessionID: UUID(), message: "Notifications are on. Your agents can reach you here.")
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["sessionID"] as? String).flatMap(UUID.init(uuidString:))
        let action = AgentNotificationAction(rawValue: response.actionIdentifier)
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            defer { completionHandler() }
            guard let id else { return }
            switch action {
            case .open, nil:  // nil is a plain click on the banner
                requestedSession = id
            case .resume:
                perform(.resume, id, nil)
                requestedSession = id
            case let action?:
                perform(action, id, text)
            }
        }
    }
}
