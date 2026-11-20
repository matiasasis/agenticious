import SwiftUI
import XCTest
@testable import Agenticious

@MainActor
final class SessionDetailLayoutTests: XCTestCase {
    private func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }

    /// The agent page is never wider than its column: if it were, everything under its header would shift past the
    /// column's left edge, the start of a command on a permission card included, with Allow still enabled.
    func testThePageStaysWithinANarrowColumnAtLargeTextWithACardUp() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(databaseURL: folder.appendingPathComponent("test.sqlite"), port: 0)
        let rule: [String: Any] = ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "make:*"]],
                                   "behavior": "allow", "destination": "session"]
        for (scale, widths) in [(1.0, [540.0, 620]), (1.25, [400.0, 480, 525]), (1.5, [330.0, 360, 480, 560])] as [(CGFloat, [CGFloat])] {
            for width in widths {
                let session = AgentSession(task: "Tidy the build", agent: .claude, project: Project(path: "/code/a-project-with-a-long-name/app"),
                                           directory: URL(fileURLWithPath: "/code/app"))
                session.isRunning = true
                session.status = .working
                PermissionInterpreter.hold(["tool_name": "Bash", "tool_input": ["command": "touch build/ready", "description": "Mark the build ready"],
                                            "cwd": "/code/app", "permission_suggestions": [rule]], in: session, respond: { _ in })
                let host = NSHostingView(rootView: SessionDetailView(session: session)
                    .frame(width: width, height: 1400).environmentObject(store).environment(\.textScale, scale))
                host.frame = CGRect(x: 0, y: 0, width: width, height: 1400)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                host.layoutSubtreeIfNeeded()
                let scrollers = all(host).compactMap { $0 as? NSScrollView }.map { host.convert($0.bounds, from: $0) }
                XCTAssertFalse(scrollers.isEmpty, "the card is drawn at \(scale)x, \(width) pt")
                for frame in scrollers {
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(scale)x, \(width) pt: \(frame)")
                    XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "\(scale)x, \(width) pt: \(frame)")
                }
            }
        }
    }
}
