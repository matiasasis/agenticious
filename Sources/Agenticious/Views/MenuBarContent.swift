import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var usage: UsageMonitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Usage & limits").font(.title3.bold())
                    Text("All your clients, at a glance").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { usage.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(usage.isRefreshing)
                .help("Refresh usage")
                .accessibilityLabel("Refresh usage")
            }.padding(18)

            ScrollView {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 12) {
                        ProviderUsageCard(agent: .codex, date: context.date)
                        ProviderUsageCard(agent: .claude, date: context.date)
                    }.padding(.horizontal, 18).padding(.bottom, 14)
                }
            }
            .frame(maxHeight: 510)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                Button("Open Agenticious") {
                    dismiss()
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }.keyboardShortcut("o")
                Button("Dashboard") {
                    dismiss()
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }.padding(14)
        }
        .frame(width: 400)
        .background(AgenticiousStyle.ink)
        .preferredColorScheme(.dark)
        .onAppear { usage.refresh() }
    }

}

struct ProviderUsageCard: View {
    @EnvironmentObject private var usage: UsageMonitor
    let agent: AgentKind
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProviderIcon(agent: agent, size: 20)
                Text(agent.displayName).font(.headline)
                Spacer()
                Text(agent == .codex ? "Session logs" : "Status line")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if agent == .codex {
                limits(usage.codexLimits.account, at: date,
                       empty: "No limits reported yet. Run a Codex session to record usage.")
                ForEach(usage.codexLimits.models, id: \.name) { model in
                    Divider()
                    Text(model.name).font(.subheadline.weight(.semibold))
                    limits(model.limits, at: date, empty: "No limit reading available.")
                }
                if let reading = usage.codexModelQuotas, !reading.quotas.isEmpty {
                    Divider()
                    Text("Model availability").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(reading.quotas) { quota in
                        CodexModelQuotaStatus(quota: quota, checkedAt: reading.checkedAt,
                                              isStale: usage.codexModelQuotasStale)
                    }
                }
                if usage.codexModelQuotasStale {
                    Text("Model availability could not be refreshed.").font(.caption).foregroundStyle(.orange)
                }
                Text("Latest recorded usage · updates when Codex reports limits")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                limits(usage.claudeReading?.limits ?? [], at: date,
                       empty: "Limits appear after a Claude agent started here reports usage.")
                if usage.claudeReading == nil, let tokens = usage.claudeTokensToday {
                    Text("Today: \(tokens.formatted(.number.notation(.compactName))) tokens")
                        .font(.subheadline.weight(.medium))
                    Text("Input, output & cache writes · not a plan limit")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let reading = usage.claudeReading {
                    Text("Reported \(reading.takenAt.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if usage.isRefreshing {
                Text("Checking for updates…").font(.caption).foregroundStyle(.secondary)
            } else if let checked = usage.lastChecked {
                Text("Checked \(checked.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgenticiousStyle.violet.opacity(0.25)))
    }

    @ViewBuilder
    private func limits(_ limits: [UsageLimit], at date: Date, empty: String) -> some View {
        if limits.isEmpty {
            Text(empty).font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(limits, id: \.windowMinutes) { limit in
                MenuLimitRow(limit: limit, date: date)
            }
        }
    }
}

struct MenuLimitRow: View {
    let limit: UsageLimit
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(limit.windowLabel).fontWeight(.medium)
                Spacer()
                if let used = limit.reportedUsedPercent(at: date) {
                    Text("\(used.formatted(.number.precision(.fractionLength(0))))% used")
                        .fontWeight(.semibold).monospacedDigit()
                } else {
                    Text("Awaiting update").foregroundStyle(.secondary)
                }
            }.font(.callout)
            if let used = limit.reportedUsedPercent(at: date) {
                UsageProgressBar(usedPercent: used)
                    .accessibilityLabel("\(limit.windowLabel) usage")
                    .accessibilityValue("\(Int(used.rounded())) percent used")
            }
            if let reset = limit.resetsAt {
                Text(reset <= date ? "Previous window ended · waiting for a new reading" :
                     "Resets \(reset.formatted(.relative(presentation: .named))) · \(reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Reset time unavailable").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
