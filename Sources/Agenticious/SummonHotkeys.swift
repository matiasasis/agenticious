import AppKit
import Combine

/// Keeps the system-wide shortcuts in step with the presets, and opens the floating Summon window when one is pressed.
@MainActor
final class SummonHotkeys: ObservableObject {
    /// Why a preset's shortcut isn't working, by preset id; shown on its card in Customize.
    @Published private(set) var problems: [String: String] = [:]
    /// Nothing is registered while a shortcut is being recorded, so pressing one already in use records it instead of firing it.
    var isRecording = false { didSet { if isRecording != oldValue { register() } } }

    private let center = HotkeyCenter()
    private let panel = SummonPanelController()
    private var plan = HotkeyPlan(presets: [])
    private var subscriptions: Set<AnyCancellable> = []
    private weak var store: SessionStore?

    /// Only the app's store calls this: one built in a test reads the same presets file, and must not take over the user's keys.
    func start(_ store: SessionStore) {
        guard self.store == nil else { return }
        self.store = store
        center.onPress = { [weak self] in self?.pressed($0) }
        // Saving, deleting and reordering all republish the presets; the sink also gets the ones loaded at launch.
        store.presets.$presets.sink { [weak self] presets in
            self?.plan = HotkeyPlan(presets: presets)
            self?.register()
        }.store(in: &subscriptions)
        // macOS drops them with the process anyway; this leaves none behind while the app shuts down.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.center.unregisterAll() }.store(in: &subscriptions)
    }

    func show(presetID: String, in store: SessionStore) { panel.show(presetID: presetID, store: store) }

    private func register() {
        var problems = plan.problems
        let refused = center.register(isRecording ? [] : plan.bindings.map(\.hotkey))
        for binding in plan.bindings where refused.contains(where: binding.hotkey.matches) {
            problems[binding.presetID] = "macOS wouldn't register \(binding.hotkey.display). Try another shortcut."
        }
        if problems != self.problems { self.problems = problems }
    }

    private func pressed(_ hotkey: Hotkey) {
        guard let store, let binding = plan.bindings.first(where: { $0.hotkey.matches(hotkey) }) else { return }
        show(presetID: binding.presetID, in: store)
    }
}
