import XCTest
@testable import Agenticious

final class BackgroundRefreshTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "BackgroundRefreshTests")
        defaults.removePersistentDomain(forName: "BackgroundRefreshTests")
    }

    func testChecksUseTheRecommendedIntervalUntilOneIsPicked() {
        let now = Date()
        XCTAssertTrue(BackgroundCheck.providers.isDue(lastChecked: nil, now: now, defaults: defaults))
        XCTAssertFalse(BackgroundCheck.providers.isDue(lastChecked: now.addingTimeInterval(-5 * 3600), now: now, defaults: defaults))
        XCTAssertTrue(BackgroundCheck.providers.isDue(lastChecked: now.addingTimeInterval(-6 * 3600), now: now, defaults: defaults))

        defaults.set(3600.0, forKey: BackgroundCheck.providers.defaultsKey)
        XCTAssertTrue(BackgroundCheck.providers.isDue(lastChecked: now.addingTimeInterval(-3600), now: now, defaults: defaults))
    }

    func testManualChecksNeverRunOnTheirOwn() {
        defaults.set(0.0, forKey: BackgroundCheck.providers.defaultsKey)
        XCTAssertFalse(BackgroundCheck.providers.isDue(lastChecked: nil, defaults: defaults))
    }

    func testEveryOptionHasALabelAndTheRecommendationIsOffered() {
        for check in BackgroundCheck.allCases {
            XCTAssertTrue(check.options.contains(check.recommended))
        }
        XCTAssertEqual(BackgroundCheck.providers.options.map(BackgroundCheck.label(for:)), [
            "Every hour", "Every 3 hours", "Every 6 hours", "Every 12 hours", "Once a day", "Only when I press Refresh"
        ])
        XCTAssertEqual(BackgroundCheck.usage.options.map(BackgroundCheck.label(for:)), [
            "Every minute", "Every 5 minutes", "Every 15 minutes", "Every 30 minutes", "Every hour"
        ])
    }

    @MainActor
    func testOnlyChecksPastTheirIntervalRun() {
        let now = Date()
        var ran: [BackgroundCheck] = []
        let refresh = BackgroundRefresh(jobs: [
            .init(check: .providers, lastChecked: { now.addingTimeInterval(-60) }, run: { ran.append(.providers) }),
            .init(check: .usage, lastChecked: { now.addingTimeInterval(-600) }, run: { ran.append(.usage) }),
        ], defaults: defaults)
        refresh.setAppActive(true)
        ran = []
        refresh.runDueChecks(now: now)
        XCTAssertEqual(ran, [.usage])
    }

    func testCodexLogsComeFromTheNewestDayFoldersByModificationDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func log(_ day: String, _ name: String, used: Double, modified: TimeInterval) throws {
            let folder = root.appendingPathComponent(day)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(name + ".jsonl")
            let line = #"{"payload":{"rate_limits":{"primary":{"used_percent":\#(used),"window_minutes":300}}}}"#
            try line.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: modified)], ofItemAtPath: file.path)
        }
        try log("2026/08/01", "stale", used: 99, modified: 0)
        try log("2026/09/28", "older", used: 10, modified: -300)
        try log("2026/09/29", "still-running", used: 50, modified: -10)
        try log("2026/09/30", "today", used: 20, modified: -120)

        XCTAssertEqual(UsageReader.recentCodexLogs(in: root).map { $0.deletingPathExtension().lastPathComponent },
                       ["still-running", "today", "older"])
        XCTAssertEqual(UsageReader.codexLimits(sessions: root).account.first?.usedPercent, 50)
    }

    func testCodexModelLimitsAreReadApartFromTheAccountLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func log(_ name: String, _ lines: [String], modified: TimeInterval) throws {
            let folder = root.appendingPathComponent("2026/10/02")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(name + ".jsonl")
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: modified)], ofItemAtPath: file.path)
        }
        func line(_ id: String, _ name: String?, used: Double) -> String {
            let limitName = name.map { #""\#($0)""# } ?? "null"
            return #"{"payload":{"rate_limits":{"limit_id":"\#(id)","limit_name":\#(limitName),"#
                + #""primary":{"used_percent":\#(used),"window_minutes":10080},"secondary":null}}}"#
        }
        try log("spark-session", [line("codex", nil, used: 40), line("codex_bengalfox", "GPT-5.3-Codex-Spark", used: 12)],
                modified: -300)
        let empty = #"{"payload":{"rate_limits":{"limit_id":"premium","limit_name":null,"primary":null,"secondary":null}}}"#
        try log("latest", [line("codex", nil, used: 70), empty], modified: -10)

        let limits = UsageReader.codexLimits(sessions: root)
        XCTAssertEqual(limits.account.map(\.usedPercent), [70])
        XCTAssertEqual(limits.models.map(\.name), ["GPT-5.3-Codex-Spark"])
        XCTAssertEqual(limits.models.first?.limits.map(\.usedPercent), [12])
    }
}
