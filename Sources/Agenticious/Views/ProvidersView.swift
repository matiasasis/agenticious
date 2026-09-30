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
                    .buttonStyle(AgenticiousButtonStyle()).disabled(diagnostics.isBusy)
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
                .disabled(diagnostics.isBusy)
                Text(diagnostics.project.path ?? FileManager.default.homeDirectoryForCurrentUser.path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(AgentKind.allCases) { agent in
                    ProviderCard(agent: agent, report: diagnostics.reports[agent], isChecking: diagnostics.isBusy)
                }
                Text("Checks reflect the selected folder, not an existing agent’s worktree or session overrides. Refresh after signing in or changing configuration. Server URLs, tokens, and raw command output are not displayed.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .alert("Could not disconnect", isPresented: Binding(
            get: { diagnostics.disconnectError != nil },
            set: { if !$0 { diagnostics.disconnectError = nil } }
        )) {
            Button("OK", role: .cancel) { diagnostics.disconnectError = nil }
        } message: {
            Text(diagnostics.disconnectError ?? "")
        }
        .onChange(of: diagnostics.project) { _, _ in Task { await diagnostics.refresh() } }
    }
}

private struct ProviderCard: View {
    @EnvironmentObject private var diagnostics: ProviderDiagnostics
    @State private var serverToDisconnect: String?

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
                    if check.isClaudeAIConnector {
                        Link("Manage in Claude", destination: URL(string: "https://claude.ai/customize/connectors")!)
                            .font(.callout)
                            .help("Disconnect account connectors in Claude’s connector settings.")
                    } else if let server = check.serverName {
                        Button("Disconnect", role: .destructive) { serverToDisconnect = server }
                            .buttonStyle(AgenticiousButtonStyle(isPrimary: false, isCompact: true))
                            .disabled(isChecking)
                            .accessibilityLabel("Disconnect \(server) from \(agent.rawValue)")
                    }
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
        .alert("Disconnect \(serverToDisconnect ?? "server")?", isPresented: Binding(
            get: { serverToDisconnect != nil },
            set: { if !$0 { serverToDisconnect = nil } }
        ), presenting: serverToDisconnect) { server in
            Button("Disconnect", role: .destructive) {
                Task { await diagnostics.disconnect(server, from: agent) }
            }
            Button("Cancel", role: .cancel) { serverToDisconnect = nil }
        } message: { _ in
            Text("This removes the server’s saved configuration for this provider, using the selected folder. Shared or user-level configuration can affect other projects. To reconnect, add the server again. Existing sessions may need to restart.")
        }
    }
}

struct ProviderStatusButton: View {
    @State private var showingStatus = false
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var diagnostics: ProviderDiagnostics

    var body: some View {
        Button {
            showingStatus.toggle()
        } label: {
            Label(diagnostics.attentionCount > 0 ? "\(diagnostics.attentionCount) warnings" : "Providers",
                  systemImage: diagnostics.attentionCount > 0 ? "exclamationmark.triangle.fill" : "network")
                .foregroundStyle(diagnostics.attentionCount > 0 ? Color.orange : AgenticiousStyle.violet)
        }
        .help("\(diagnostics.attentionCount) provider warnings · \(diagnostics.project.path ?? "Home folder")")
        .popover(isPresented: $showingStatus) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Provider connections").font(.headline)
                Text(diagnostics.project.name == "No project" ? "Home folder" : diagnostics.project.name)
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(AgentKind.allCases) { agent in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            AgentBadge(agent: agent)
                            Spacer()
                            let count = diagnostics.reports[agent]?.attentionCount ?? 0
                            Text(diagnostics.isChecking ? "Checking…" : diagnostics.reports[agent] == nil ? "Not checked" : count > 0 ? "\(count) need attention" : "No warnings reported")
                                .font(.caption).foregroundStyle(count > 0 ? Color.orange : .secondary)
                        }
                        ForEach(Array((diagnostics.reports[agent]?.checks.filter(\.needsAttention) ?? []).prefix(3))) { check in
                            Text(check.id + ": " + check.message).font(.caption).foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                    }
                }
                Text("Codex reports configured authentication; live connections are not checked.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await diagnostics.refresh() } }
                        .disabled(diagnostics.isBusy)
                        .buttonStyle(AgenticiousButtonStyle(isPrimary: false, isCompact: true))
                    Spacer()
                    Button("Manage providers") {
                        showingStatus = false
                        store.selection = .providers
                    }.buttonStyle(AgenticiousButtonStyle(isCompact: true))
                }
            }.padding(20).frame(width: 360).background(AgenticiousStyle.ink)
        }
    }
}
