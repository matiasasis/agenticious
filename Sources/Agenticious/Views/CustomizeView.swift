import SwiftUI

struct CustomizeView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("CUSTOMIZE").font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1).foregroundStyle(.secondary).padding(.trailing, 12)
                tab("Task presets", symbol: "square.stack", selection: .settings)
                tab("Skills", symbol: "books.vertical", selection: .skills)
                tab("Preferences", symbol: "slider.horizontal.3", selection: .preferences)
                Spacer(minLength: 0)
            }.padding(20).background(AgenticiousStyle.panel)
            switch store.selection {
            case .skills: SkillLibraryView()
            case .preferences: PreferencesView()
            default: TaskSettingsView()
            }
        }
    }

    private func tab(_ title: String, symbol: String, selection: Selection) -> some View {
        Button { store.selection = selection } label: { Label(title, systemImage: symbol) }
            .buttonStyle(AgenticiousButtonStyle(isPrimary: store.selection == selection, isCompact: true))
            .accessibilityAddTraits(store.selection == selection ? .isSelected : [])
    }
}

enum PreferencesSection: String, CaseIterable, Identifiable {
    case general
    case notifications
    case refresh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .refresh: "Background refresh"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell.badge"
        case .refresh: "arrow.triangle.2.circlepath"
        }
    }
}

private struct PreferencesView: View {
    @AppStorage("preferencesSection") private var section = PreferencesSection.general

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(PreferencesSection.allCases) { item in
                    Button { section = item } label: {
                        Label(item.title, systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .foregroundStyle(section == item ? AgenticiousStyle.lime : Color.primary)
                            .background(section == item ? AgenticiousStyle.panel : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
            .padding(20).frame(width: 230)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(section.title).font(.system(size: 30, weight: .bold, design: .rounded))
                    switch section {
                    case .general: GeneralPreferencesView()
                    case .notifications: NotificationPreferencesView()
                    case .refresh: RefreshPreferencesView()
                    }
                }
                .padding(28).frame(maxWidth: 760, alignment: .leading)
            }
        }
    }
}

private struct GeneralPreferencesView: View {
    @AppStorage("sidebarShowBranches") private var showBranches = true
    @AppStorage("useWorktree") private var useWorktree = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("Show branch names in the agent sidebar", isOn: $showBranches)
            Divider()
            Toggle("Use a separate worktree for new agents", isOn: $useWorktree)
            Text("Applies to git projects. You can change this for each mission when summoning an agent.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .toggleStyle(.switch).padding(20)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct RefreshPreferencesView: View {
    @AppStorage(BackgroundCheck.providers.defaultsKey) private var providers = BackgroundCheck.providers.recommended
    @AppStorage(BackgroundCheck.usage.defaultsKey) private var usage = BackgroundCheck.usage.recommended

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Provider checks run while Agenticious is the app in front. Usage also refreshes while the companion dashboard is visible. When you come back to it, anything older than its interval refreshes right away; switching back and forth in between doesn't trigger extra checks.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Use recommended for all", systemImage: "wand.and.stars") {
                providers = BackgroundCheck.providers.recommended
                usage = BackgroundCheck.usage.recommended
            }
            .buttonStyle(AgenticiousButtonStyle())
            .disabled(providers == BackgroundCheck.providers.recommended && usage == BackgroundCheck.usage.recommended)
            row(.providers, selection: $providers)
            row(.usage, selection: $usage)
        }
    }

    private func row(_ check: BackgroundCheck, selection: Binding<TimeInterval>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(check.title).font(.headline)
                Spacer()
                Picker(check.title, selection: selection) {
                    ForEach(check.options, id: \.self) { interval in
                        Text(BackgroundCheck.label(for: interval) + (interval == check.recommended ? " (recommended)" : ""))
                            .tag(interval)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            Text(check.detail).font(.callout).foregroundStyle(.secondary)
            Label("Best fit: \(BackgroundCheck.label(for: check.recommended).lowercased()). \(check.reason)", systemImage: "star.fill")
                .font(.caption).foregroundStyle(AgenticiousStyle.violet)
        }
        .padding(20)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
    }
}
