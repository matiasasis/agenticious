import SwiftUI

struct CustomizeView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("CUSTOMIZE").scaledFont(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1).foregroundStyle(.secondary).padding(.trailing, 12)
                Group {
                    tab("Task presets", symbol: "square.stack", selection: .settings)
                    tab("Skills", symbol: "books.vertical", selection: .skills)
                    tab("Preferences", symbol: "slider.horizontal.3", selection: .preferences)
                }.layoutPriority(1)
                Spacer(minLength: 0)
                // Short of room (larger text, a narrow window), it shrinks to its arrow before a tab wraps.
                ViewThatFits(in: .horizontal) {
                    backToQueue
                    backToQueue.labelStyle(.iconOnly).help("Back to queue")
                }
            }.padding(20).background(AgenticiousStyle.panel)
            switch store.selection {
            case .skills: SkillLibraryView()
            case .preferences: PreferencesView()
            default: TaskSettingsView()
            }
        }
    }

    private var backToQueue: some View {
        Button("Back to queue", systemImage: "arrow.left") { store.show(.queue) }
            .buttonStyle(AgenticiousButtonStyle(isPrimary: false, isCompact: true))
    }

    private func tab(_ title: String, symbol: String, selection: Selection) -> some View {
        Button { store.selection = selection } label: { Label(title, systemImage: symbol) }
            .buttonStyle(AgenticiousButtonStyle(isPrimary: store.selection == selection, isCompact: true))
            .accessibilityAddTraits(store.selection == selection ? .isSelected : [])
    }
}

enum PreferencesSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case notifications
    case refresh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .refresh: "Background refresh"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "textformat.size"
        case .notifications: "bell.badge"
        case .refresh: "arrow.triangle.2.circlepath"
        }
    }
}

private struct PreferencesView: View {
    @AppStorage("preferencesSection") private var section = PreferencesSection.general
    @Environment(\.textScale) private var textScale

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(PreferencesSection.allCases) { item in
                    Button { section = item } label: {
                        // Icons of different widths in one column, so every title starts at the same place.
                        Label { Text(item.title) } icon: { Image(systemName: item.symbol).scaledFrame(width: 18) }
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
            // Wider with larger text, but by what its longest title needs, not by the whole factor: the pane beside it
            // needs the room more.
            .padding(20).frame(width: 230 + 80 * (textScale - 1))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(section.title).scaledFont(.system(size: 30, weight: .bold, design: .rounded))
                    switch section {
                    case .general: GeneralPreferencesView()
                    case .appearance: AppearancePreferencesView()
                    case .notifications: NotificationPreferencesView()
                    case .refresh: RefreshPreferencesView()
                    }
                }
                .padding(28).frame(maxWidth: 760, alignment: .leading)
                // Narrower than the pane, the page keeps to the left beside the section list rather than centring.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct GeneralPreferencesView: View {
    @AppStorage("useWorktree") private var useWorktree = true
    @AppStorage(SummonPosition.defaultsKey) private var summonPosition = SummonPosition.mainDisplay
    @Environment(\.textScale) private var textScale

    var body: some View {
        PreferencesPanel {
            Toggle("Use a separate worktree for new agents", isOn: $useWorktree)
            Text("Applies to git projects. You can change this for each mission when summoning an agent.")
                .scaledFont(.caption).foregroundStyle(.secondary)
            Divider()
            PreferencesMenuRow(title: "Summon window opens", picker: Picker("Summon window opens", selection: $summonPosition) {
                ForEach(SummonPosition.allCases) { position in
                    Text(position.title + (position == .mainDisplay ? " (default)" : "")).scaledFont(.body, textScale).tag(position)
                }
            })
            Text("Where a preset's shortcut or a Stream Deck key opens the floating Summon window. The main display is the one with the menu bar.")
                .scaledFont(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AppearancePreferencesView: View {
    @AppStorage("sidebarShowBranches") private var showBranches = true
    @AppStorage(TextScale.key) private var storedTextScale = 1.0
    @Environment(\.textScale) private var textScale

    /// A size between two steps (from `-textScale`) shows as the nearer one.
    private var textSize: Binding<Double> {
        Binding { TextScale.nearestStep(to: storedTextScale) } set: { TextScale.store($0) }
    }

    var body: some View {
        PreferencesPanel {
            PreferencesMenuRow(title: "Text size", picker: Picker("Text size", selection: textSize) {
                ForEach(TextScale.steps, id: \.self) { step in
                    Text(TextScale.label(step) + (step == 1 ? " (default)" : "")).scaledFont(.body, textScale).tag(step)
                }
            })
            Text("Scales all text in Agenticious, the terminal included. ⌘+ and ⌘− change it too; ⌘0 puts it back.")
                .scaledFont(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Show branch names in the agent sidebar", isOn: $showBranches)
        }
    }
}

/// The rounded panel a preferences page's rows sit in.
private struct PreferencesPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) { content }
            .toggleStyle(.switch).padding(20)
            .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// A title with its pop-up beside it. With larger text in a narrow window the pop-up goes under its title instead
/// of squeezing it out.
private struct PreferencesMenuRow<Control: View>: View {
    let title: String
    let picker: Control
    @Environment(\.textScale) private var textScale

    var body: some View {
        let title = Text(title)
        let picker = picker.labelsHidden().pickerStyle(.menu).fixedSize(horizontal: textScale == 1, vertical: true)
        let sideBySide = HStack(alignment: .firstTextBaseline) { title; Spacer(); picker.fixedSize() }
        if textScale == 1 {
            sideBySide
        } else {
            ViewThatFits(in: .horizontal) {
                sideBySide
                VStack(alignment: .leading, spacing: 12) { title; picker }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct RefreshPreferencesView: View {
    @AppStorage(BackgroundCheck.providers.defaultsKey) private var providers = BackgroundCheck.providers.recommended
    @AppStorage(BackgroundCheck.usage.defaultsKey) private var usage = BackgroundCheck.usage.recommended
    @Environment(\.textScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Checks only run while Agenticious is the app in front. When you come back to it, anything older than its interval refreshes right away; switching back and forth in between doesn't trigger extra checks.")
                .scaledFont(.callout).foregroundStyle(.secondary)
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
            let title = Text(check.title).scaledFont(.headline)
            let picker = Picker(check.title, selection: selection) {
                ForEach(check.options, id: \.self) { interval in
                    Text(BackgroundCheck.label(for: interval) + (interval == check.recommended ? " (recommended)" : ""))
                        .scaledFont(.body, textScale).tag(interval)
                }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize(horizontal: textScale == 1, vertical: true)
            let sideBySide = HStack(alignment: .firstTextBaseline) { title; Spacer(); picker.fixedSize() }
            // The pop-up never shrinks, so with larger text it goes under a title it would leave no room for.
            if textScale == 1 {
                sideBySide
            } else {
                ViewThatFits(in: .horizontal) {
                    sideBySide
                    VStack(alignment: .leading, spacing: 12) { title; picker }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(check.detail).scaledFont(.callout).foregroundStyle(.secondary)
            Label("Best fit: \(BackgroundCheck.label(for: check.recommended).lowercased()). \(check.reason)", systemImage: "star.fill")
                .scaledFont(.caption).foregroundStyle(AgenticiousStyle.violet)
        }
        .padding(20)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
    }
}
