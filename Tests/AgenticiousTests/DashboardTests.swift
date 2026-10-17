import SwiftUI
import XCTest
@testable import Agenticious

final class DashboardTests: XCTestCase {
    @MainActor
    func testShortcutChoicesPersistAndMissingPresetsAndWorkspacesAreIgnored() {
        let suite = "DashboardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DashboardPreferences(defaults: defaults)
        settings.pinnedPresetIDs = []
        settings.setPinned(true, preset: .chat)
        settings.setPinned(true, preset: .chat)
        settings.pinnedPresetIDs.append("deleted")
        settings.workspacePath = "/gone"
        let restored = DashboardPreferences(defaults: defaults)
        XCTAssertEqual(restored.shortcuts(from: TaskTemplate.defaults).map(\.id), ["chat"])
        XCTAssertEqual(restored.workspace(from: []), .none)
        XCTAssertEqual(restored.workspace(from: [Project(path: "/gone")]), Project(path: "/gone"))
        restored.setPinned(false, preset: .chat)
        XCTAssertTrue(restored.shortcuts(from: TaskTemplate.defaults).isEmpty)
    }

    @MainActor
    func testWindowReturnsToAnAttachedDisplayAndClampsItsSize() {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let corsair = CGRect(x: -2560, y: 0, width: 2560, height: 720)
        XCTAssertEqual(DashboardWindow.restoredFrame(corsair, screens: [main, corsair], fallback: main), corsair)
        XCTAssertEqual(DashboardWindow.restoredFrame(corsair, screens: [main], fallback: main), main)
        let oversized = CGRect(x: 1700, y: 900, width: 2560, height: 1200)
        XCTAssertEqual(DashboardWindow.restoredFrame(oversized, screens: [main], fallback: main), main)
    }

    @MainActor
    func testDashboardVisibilityKeepsOnlyUsageRefreshingInBackground() {
        let suite = "DashboardRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks: [BackgroundCheck] = []
        let refresh = BackgroundRefresh(jobs: [
            .init(check: .usage, lastChecked: { nil }, run: { checks.append(.usage) }),
            .init(check: .providers, lastChecked: { nil }, run: { checks.append(.providers) }),
        ], defaults: defaults)
        refresh.setAppActive(false)
        checks = []
        refresh.runDueChecks()
        XCTAssertTrue(checks.isEmpty)
        refresh.setDashboardVisible(true)
        XCTAssertEqual(checks, [.usage])
        checks = []
        refresh.setAppActive(true)
        XCTAssertEqual(checks, [.usage, .providers])
        refresh.setAppActive(false)
        refresh.setDashboardVisible(false)
        checks = []
        refresh.runDueChecks()
        XCTAssertTrue(checks.isEmpty)
    }

    @MainActor
    func testDashboardPrioritizesAttentionAndRendersWideAndCompactWindows() throws {
        let root = ProcessInfo.processInfo.environment["DASHBOARD_TEST_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let folder = root.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let databaseURL = folder.appendingPathComponent("sessions.sqlite")
        let database = try SessionDatabase(url: databaseURL)
        let titles = ["Build the companion dashboard", "Review the new onboarding flow", "Investigate intermittent CI failures", "Update workspace documentation"]
        var ids: [UUID] = []
        for (index, title) in titles.enumerated() {
            let session = AgentSession(task: title, agent: index % 2 == 0 ? .codex : .claude,
                                       project: Project(path: "/projects/Agenticious"), directory: folder)
            session.chunks = [Chunk(id: 1, title: "Explore the code", status: .done),
                              Chunk(id: 2, title: "Implement and validate", status: .inProgress),
                              Chunk(id: 3, title: "Publish the result", status: .pending)]
            try database.save(session)
            ids.append(session.id)
        }
        let store = SessionStore(databaseURL: databaseURL, listensForEvents: false)
        for session in store.sessions { session.status = .working; session.isRunning = true }
        let attention = try XCTUnwrap(store.session(ids[1]))
        attention.status = .needsYou("Choose which onboarding variant to keep.")
        store.session(ids[3])?.status = .done("Documentation is ready to read.")
        XCTAssertEqual(store.dashboardSessions.first?.id, attention.id)
        XCTAssertEqual(attention.dashboardDetail, "Choose which onboarding variant to keep.")
        store.session(ids[2])?.isMarkedFinished = true
        XCTAssertFalse(store.dashboardSessions.contains { $0.id == ids[2] })
        let suite = "DashboardRendering-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let usage = UsageMonitor(defaults: defaults)
        let presets = TaskPresetStore(url: folder.appendingPathComponent("presets.json"), defaults: defaults)
        let preferences = DashboardPreferences(defaults: defaults)
        usage.recordClaudeRateLimits([
            "five_hour": ["used_percentage": 32.0, "resets_at": Date().addingTimeInterval(7200).timeIntervalSince1970],
            "seven_day": ["used_percentage": 68.0, "resets_at": Date().addingTimeInterval(172800).timeIntervalSince1970],
        ])
        let metrics = SystemMetricsMonitor(current: SystemMetrics(cpu: 0.37, memoryUsed: 24 * 1024 * 1024 * 1024,
                                                                  memoryTotal: 64 * 1024 * 1024 * 1024, pressure: 1,
                                                                  diskFree: 428_000_000_000, diskTotal: 1_000_000_000_000),
                                           cpuHistory: (0..<60).map { 0.3 + sin(Double($0) * 0.8) * 0.12 })
        for size in [CGSize(width: 2560, height: 720), CGSize(width: 1200, height: 600)] {
            let root = CompanionDashboardView(metrics: metrics, preferences: preferences, tracksWindow: false)
                .environmentObject(store).environmentObject(usage).environmentObject(presets)
            let view = NSHostingView(rootView: root)
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            XCTAssertEqual(view.frame.size, size)
            if let directory = ProcessInfo.processInfo.environment["DASHBOARD_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let path = URL(fileURLWithPath: directory).appendingPathComponent("dashboard-\(Int(size.width)).png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: path)
            }
        }
    }
}
