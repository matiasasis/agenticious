import XCTest
@testable import Agenticious

final class AgentLauncherTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    @MainActor
    func testStartupSwitchesAreSetForStartUpAndUnsetBeforeTheCLIRuns() throws {
        for agent in AgentKind.allCases {
            for resuming in [false, true] {
                let session = AgentSession(task: "Fix it", agent: agent, project: .none, directory: folder)
                session.conversationID = UUID().uuidString
                let launcher = AgentLauncher(port: 1, supportDirectory: folder, inherited: ["PATH": "/usr/bin:/bin"])
                let spec = try launcher.spec(for: session, resuming: resuming)
                XCTAssertTrue(spec.environment.contains("DISABLE_AUTO_UPDATE=true"))
                XCTAssertTrue(spec.environment.contains("ZSH_TMUX_AUTOSTARTED=true"))
                XCTAssertFalse(spec.environment.contains { $0.hasPrefix("DISABLE_UPDATE_PROMPT=") })
                let exec = agent == .claude ? "exec claude" : resuming ? "exec codex resume" : "exec codex"
                XCTAssertTrue(spec.arguments[1].hasPrefix("unset DISABLE_AUTO_UPDATE ZSH_TMUX_AUTOSTARTED; " + exec), spec.arguments[1])
            }
        }
    }

    @MainActor
    func testTheUsersOwnSettingIsLeftAloneAndNotUnset() throws {
        let session = AgentSession(task: "Fix it", agent: .claude, project: .none, directory: folder)
        let launcher = AgentLauncher(port: 1, supportDirectory: folder, inherited: ["DISABLE_AUTO_UPDATE": "false"])
        let spec = try launcher.spec(for: session)
        XCTAssertTrue(spec.environment.contains("DISABLE_AUTO_UPDATE=false"))
        XCTAssertFalse(spec.environment.contains("DISABLE_AUTO_UPDATE=true"))
        XCTAssertTrue(spec.arguments[1].hasPrefix("unset ZSH_TMUX_AUTOSTARTED; exec claude"), spec.arguments[1])

        let both = AgentLauncher(port: 1, supportDirectory: folder, inherited: ["DISABLE_AUTO_UPDATE": "true", "ZSH_TMUX_AUTOSTARTED": "true"])
        XCTAssertTrue(try both.spec(for: session).arguments[1].hasPrefix("exec claude"))
    }
}
