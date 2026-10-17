import SwiftUI

struct CompanionDashboardView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var presets: TaskPresetStore
    @EnvironmentObject private var usage: UsageMonitor
    @Environment(\.openWindow) private var openWindow
    @StateObject private var metrics: SystemMetricsMonitor
    @StateObject private var preferences: DashboardPreferences
    @State private var visible = false
    @State private var customizing = false
    var tracksWindow = true

    init(metrics: SystemMetricsMonitor? = nil, preferences: DashboardPreferences? = nil, tracksWindow: Bool = true) {
        _metrics = StateObject(wrappedValue: metrics ?? SystemMetricsMonitor())
        _preferences = StateObject(wrappedValue: preferences ?? DashboardPreferences())
        self.tracksWindow = tracksWindow
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = max(1, min(geometry.size.width / 1600, geometry.size.height / 620))
            content(wide: geometry.size.width / scale >= 1800)
                .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .background(AgenticiousStyle.ink)
        .preferredColorScheme(.dark)
        .tint(AgenticiousStyle.lime)
        .background {
            if tracksWindow {
                DashboardWindow { isVisible in
                    visible = isVisible
                    store.setDashboardVisible(isVisible)
                }
            }
        }
        .task(id: visible) {
            if visible { await metrics.sampleWhileVisible() }
        }
        .onDisappear { store.setDashboardVisible(false) }
    }

    private func content(wide: Bool) -> some View {
        VStack(spacing: 16) {
            header
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    DashboardSystemView(metrics: metrics.current, history: metrics.cpuHistory)
                }.frame(width: 245)
                agents(wide: wide).frame(maxWidth: .infinity, maxHeight: .infinity)
                limits(wide: wide).frame(width: wide ? 620 : 340)
            }.frame(maxHeight: .infinity)
            shortcuts
        }.padding(22)
    }

    private var header: some View {
        HStack(spacing: 22) {
            Label("CONTROL ROOM", systemImage: "sparkles")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(AgenticiousStyle.lime)
            count(store.workingCount, "working", color: AgenticiousStyle.lime)
            count(store.attentionCount, "need you", color: .orange)
            count(store.visibleSessions.count, "in queue", color: AgenticiousStyle.violet)
            Spacer()
            Button("Fit display", systemImage: "arrow.up.left.and.arrow.down.right", action: DashboardWindow.fitToDisplay)
                .buttonStyle(DashboardButtonStyle())
            Button("Open app", systemImage: "macwindow") { showMain() }
                .buttonStyle(DashboardButtonStyle())
        }
    }

    private func count(_ value: Int, _ label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text("\(value)").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
        }.monospacedDigit()
    }

    private func agents(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("AGENT ACTIVITY", symbol: "square.stack.3d.up")
            if store.dashboardSessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 36)).foregroundStyle(AgenticiousStyle.violet)
                    Text("Ready for your next idea").font(.title3.bold())
                    Text("Choose a shortcut below to summon an agent.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: wide ? 2 : 1), spacing: 10) {
                        ForEach(store.dashboardSessions) { session in
                            DashboardAgentRow(session: session) {
                                store.selection = .session(session.id)
                                showMain()
                            }
                        }
                    }
                }
            }
        }
    }

    private func limits(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("USAGE & LIMITS", symbol: "gauge.with.dots.needle.50percent")
                Spacer()
                Button { usage.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).disabled(usage.isRefreshing)
                .accessibilityLabel("Refresh usage limits")
            }.frame(height: 24)
            ScrollView {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
                    layout {
                        ProviderUsageCard(agent: .codex, date: context.date)
                        ProviderUsageCard(agent: .claude, date: context.date)
                    }
                }
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("QUICK LAUNCH", symbol: "bolt.fill")
                Spacer()
                Picker("Workspace", selection: $preferences.workspacePath) {
                    Text("No project").tag("")
                    ForEach(store.favorites) { project in Text(project.name).tag(project.path ?? "") }
                }.frame(maxWidth: 300).controlSize(.large)
                Button("Customize", systemImage: "slider.horizontal.3") { customizing = true }
                    .buttonStyle(DashboardButtonStyle())
                    .popover(isPresented: $customizing) { shortcutSettings }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(preferences.shortcuts(from: presets.presets)) { preset in
                        Button {
                            showMain()
                            store.composer = Composer(project: preferences.workspace(from: store.favorites), template: preset)
                        } label: {
                            Label(preset.name, systemImage: preset.symbol)
                                .font(.system(size: 17, weight: .semibold))
                                .frame(minWidth: 150, minHeight: 46).padding(.horizontal, 12)
                        }.buttonStyle(DashboardButtonStyle(accent: true))
                    }
                    if preferences.shortcuts(from: presets.presets).isEmpty {
                        Text("Choose your task shortcuts in Customize.").foregroundStyle(.secondary).frame(height: 70)
                    }
                }
            }
        }
        .onAppear { preferences.workspacePath = preferences.workspace(from: store.favorites).path ?? "" }
        .onChange(of: store.favorites) { _, favorites in
            preferences.workspacePath = preferences.workspace(from: favorites).path ?? ""
        }
    }

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Task shortcuts").font(.title3.bold())
            Text("Pinned tasks open on your main window, ready for input.").foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(presets.presets) { preset in
                        Toggle(isOn: Binding(get: { preferences.pinnedPresetIDs.contains(preset.id) },
                                             set: { preferences.setPinned($0, preset: preset) })) {
                            Label(preset.name, systemImage: preset.symbol)
                        }.toggleStyle(.switch).padding(.vertical, 8)
                    }
                }
            }.frame(maxHeight: 330)
            Button("Done") { customizing = false }.buttonStyle(DashboardButtonStyle(accent: true))
        }.padding(22).frame(width: 360)
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .tracking(1).foregroundStyle(.secondary)
    }

    private func showMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct DashboardAgentRow: View {
    @ObservedObject var session: AgentSession
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProviderIcon(agent: session.agent, size: 20)
                    Text(session.task).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 8)
                    Text(session.status.label).font(.system(size: 13, weight: .bold)).foregroundStyle(session.status.color)
                }
                Text(session.dashboardDetail).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Text(session.project.name)
                    if let model = session.modelSummary { Text("· \(model)") }
                    Spacer()
                    if !session.subagents.isEmpty { Text("\(session.subagents.count) subagents") }
                    if !session.chunks.isEmpty { Text("\(session.completedChunks)/\(session.chunks.count) steps") }
                }.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                if !session.chunks.isEmpty {
                    ProgressView(value: Double(session.completedChunks), total: Double(session.chunks.count))
                        .tint(session.status.color)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(session.status.needsAttention ? Color.orange.opacity(0.12) : AgenticiousStyle.panel,
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(session.status.color.opacity(session.status.needsAttention ? 0.7 : 0.2)))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}

struct DashboardSystemView: View {
    let metrics: SystemMetrics
    let history: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("THIS MAC", systemImage: "desktopcomputer")
                .font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
            tile("CPU", value: metrics.cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? (metrics.cpuUnavailable ? "Unavailable" : "Sampling…"), detail: "Across all cores", color: AgenticiousStyle.lime) {
                GeometryReader { geometry in
                    Path { path in
                        for (index, value) in history.enumerated() {
                            let point = CGPoint(x: geometry.size.width * Double(index) / 59, y: geometry.size.height * (1 - value))
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }.stroke(AgenticiousStyle.lime, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }.frame(height: 24).accessibilityLabel("CPU history, up to two minutes")
            }
            tile("MEMORY", value: SystemMetrics.bytes(metrics.memoryUsed), detail: "of \(SystemMetrics.bytes(metrics.memoryTotal)) · \(metrics.pressureLabel)", color: pressureColor) {
                meter(metrics.memoryFraction, color: pressureColor)
            }
            tile("DISK FREE", value: metrics.diskFree.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable",
                 detail: "Home volume · \(metrics.diskTotal.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown capacity")", color: AgenticiousStyle.violet) {
                meter(metrics.diskFraction, color: AgenticiousStyle.violet)
            }
            Text("Live samples every 2 seconds")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var pressureColor: Color {
        metrics.pressure == 4 ? .red : metrics.pressure == 2 ? .orange : AgenticiousStyle.lime
    }

    private func meter(_ fraction: Double?, color: Color) -> some View {
        ProgressView(value: fraction ?? 0).tint(color).opacity(fraction == nil ? 0.3 : 1)
    }

    private func tile<Content: View>(_ label: String, value: String, detail: String, color: Color, @ViewBuilder chart: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(color).monospacedDigit()
            }
            chart()
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct DashboardButtonStyle: ButtonStyle {
    var accent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(minHeight: 44)
            .foregroundStyle(accent ? AgenticiousStyle.lime : Color.primary)
            .background(accent ? AgenticiousStyle.lime.opacity(0.09) : AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke((accent ? AgenticiousStyle.lime : AgenticiousStyle.violet).opacity(0.25)))
            .brightness(configuration.isPressed ? 0.1 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
