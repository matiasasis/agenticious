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

private struct PreferencesView: View {
    @AppStorage("sidebarShowBranches") private var showBranches = true
    @AppStorage("useWorktree") private var useWorktree = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Make yourself at home.").font(.system(size: 30, weight: .bold, design: .rounded))
                NotificationPreferencesView()
                VStack(alignment: .leading, spacing: 20) {
                    Toggle("Show branch names in the agent sidebar", isOn: $showBranches)
                    Divider()
                    Toggle("Use a separate worktree for new agents", isOn: $useWorktree)
                    Text("Applies to git projects. You can change this for each mission when summoning an agent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch).padding(20)
                .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
            }.padding(28)
        }
    }
}
