import Foundation

@MainActor
final class DashboardPreferences: ObservableObject {
    @Published var pinnedPresetIDs: [String] { didSet { defaults.set(pinnedPresetIDs, forKey: "dashboardPresets") } }
    @Published var workspacePath: String { didSet { defaults.set(workspacePath, forKey: "dashboardWorkspace") } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pinnedPresetIDs = defaults.stringArray(forKey: "dashboardPresets") ?? Array(TaskTemplate.defaults.prefix(6).map(\.id))
        workspacePath = defaults.string(forKey: "dashboardWorkspace") ?? ""
    }

    func shortcuts(from presets: [TaskTemplate]) -> [TaskTemplate] {
        pinnedPresetIDs.compactMap { id in presets.first { $0.id == id } }
    }

    func setPinned(_ pinned: Bool, preset: TaskTemplate) {
        pinnedPresetIDs.removeAll { $0 == preset.id }
        if pinned { pinnedPresetIDs.append(preset.id) }
    }

    func workspace(from favorites: [Project]) -> Project {
        favorites.first { $0.path == workspacePath } ?? .none
    }
}

