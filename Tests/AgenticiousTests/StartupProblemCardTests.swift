import SwiftUI
import XCTest
@testable import Agenticious

final class StartupProblemCardTests: XCTestCase {
    /// Both kinds lay out off-screen at the normal and the largest text size, and grow with the text.
    @MainActor
    func testTheCardLaysOutForAWaitAndForALaunchThatDidNotStart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(databaseURL: folder.appendingPathComponent("test.sqlite"))
        let waiting = AgentSession(task: "Wait", agent: .claude, project: .none, directory: folder)
        waiting.isRunning = true
        StartupPromptInterpreter.apply(.shellWaiting(.claude, ShellWait(kind: .password, text: "Password:", program: "sudo")), to: waiting)
        let failed = AgentSession(task: "Fail", agent: .claude, project: .none, directory: folder)
        failed.recordExit(127, launchFailure: LaunchFailure(code: 127, output: [
            "nodenv: claude: command not found", "", "The `claude' command exists in these Node versions:", "  20.18.0",
        ], resuming: false))
        let quiet = AgentSession(task: "Fine", agent: .codex, project: .none, directory: folder)

        XCTAssertTrue(StartupProblemCard.shows(for: waiting))
        XCTAssertTrue(StartupProblemCard.shows(for: failed))
        XCTAssertFalse(StartupProblemCard.shows(for: quiet))
        for session in [waiting, failed] {
            func height(_ scale: CGFloat) -> CGFloat {
                let card = StartupProblemCard(session: session, openTerminal: {}).frame(width: 600)
                    .environmentObject(store).environment(\.textScale, scale)
                return NSHostingView(rootView: card).fittingSize.height
            }
            XCTAssertGreaterThan(height(1), 100)
            XCTAssertGreaterThan(height(1.5), height(1))
        }
    }
}
