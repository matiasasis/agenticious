import SwiftUI

struct ProvidersView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var diagnostics: ProviderDiagnostics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Keep your agents connected.").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Account access, MCP connections, and provider warnings.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(diagnostics.isChecking ? "Checking…" : "Refresh", systemImage: "arrow.clockwise") {
                        Task { await diagnostics.refresh() }
                    }
                    .buttonStyle(AgenticiousButtonStyle()).disabled(diagnostics.isChecking)
                }
                HStack {
                    Picker("Check in", selection: $diagnostics.project) {
                        Text("Home folder").tag(Project.none)
                        ForEach(store.projectGroups.filter { $0.project != .none }) { group in
                            Text(group.project.name).tag(group.project)
                        }
                    }.frame(maxWidth: 360)
                    Button("Choose folder…") {
                        if let url = FolderPicker.choose() { diagnostics.project = store.addFavorite(url) }
                    }
                }
                .disabled(diagnostics.isChecking)
                Text(diagnostics.project.path ?? FileManager.default.homeDirectoryForCurrentUser.path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(AgentKind.allCases) { agent in
                    ProviderCard(agent: agent, report: diagnostics.reports[agent], isChecking: diagnostics.isChecking)
                }
                Text("Checks reflect the selected folder, not an existing agent’s worktree or session overrides. Refresh after signing in or changing configuration. Server URLs, tokens, and raw command output are not displayed.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .onChange(of: diagnostics.project) { _, _ in Task { await diagnostics.refresh() } }
    }
}

private struct ProviderCard: View {
    let agent: AgentKind
    let report: ProviderReport?
    let isChecking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                AgentBadge(agent: agent)
                Spacer()
                if let report {
                    Text(report.attentionCount > 0 ? "\(report.attentionCount) need attention" : "No warnings reported")
                        .foregroundStyle(report.attentionCount > 0 ? Color.orange : AgenticiousStyle.violet)
                } else {
                    Text(isChecking ? "Checking…" : "Not checked").foregroundStyle(.secondary)
                }
            }
            ForEach(report?.checks ?? []) { check in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: check.needsAttention ? "exclamationmark.triangle.fill" : "circle.dotted")
                        .foregroundStyle(check.needsAttention ? Color.orange : AgenticiousStyle.violet)
                    Text(check.id).fontWeight(.semibold).frame(width: 170, alignment: .leading)
                    Text(check.message).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.textSelection(.enabled)
            }
            Divider()
            Text(agent == .claude ? "Use /mcp inside Claude Code to reconnect or approve servers." : "Use codex mcp login <server-name> for OAuth. Use /mcp inside Codex to inspect live connections.")
                .font(.callout).foregroundStyle(AgenticiousStyle.violet)
            Text(agent == .claude ? "Details: claude auth status · claude mcp list" : "Details: codex login status · codex mcp list")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if let date = report?.checkedAt {
                Text("Checked \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20).background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AgenticiousStyle.violet.opacity(0.25)))
    }
}

struct ProviderStatusButton: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var diagnostics: ProviderDiagnostics

    var body: some View {
        Button {
            store.selection = .providers
        } label: {
            Label(diagnostics.attentionCount > 0 ? "\(diagnostics.attentionCount) warnings" : "Providers",
                  systemImage: diagnostics.attentionCount > 0 ? "exclamationmark.triangle.fill" : "network")
                .foregroundStyle(diagnostics.attentionCount > 0 ? Color.orange : AgenticiousStyle.violet)
        }
        .help("\(diagnostics.attentionCount) provider warnings · \(diagnostics.project.path ?? "Home folder")")
        .task { if diagnostics.reports.isEmpty { await diagnostics.refresh() } }
    }
}
