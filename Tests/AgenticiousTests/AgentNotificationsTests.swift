import XCTest
@testable import Agenticious

final class AgentNotificationsTests: XCTestCase {
    func testImportantTransitions() {
        XCTAssertEqual(AgentAlert.transition(from: .working, to: .needsYou("Approve")), .needsYou)
        XCTAssertEqual(AgentAlert.transition(from: .working, to: .yourTurn), .yourTurn)
        XCTAssertEqual(AgentAlert.transition(from: .working, to: .done(nil)), .completed)
        XCTAssertEqual(AgentAlert.transition(from: .needsYou("Approve"), to: .ended("Handed off")), .ended)
        XCTAssertEqual(AgentAlert.transition(from: .working, to: .exited(1)), .failed)
        XCTAssertEqual(AgentAlert.transition(from: .working, to: .exited(nil)), .failed)
        // A held subagent request has no other signal, whatever the main agent was doing.
        for calm in [SessionStatus.working, .yourTurn, .waiting, .starting] {
            XCTAssertEqual(AgentAlert.transition(from: calm, to: .permissionRequired("Run command")), .permissionRequired)
        }
        XCTAssertEqual(AgentAlert.transition(from: .permissionRequired("Run command"), to: .done(nil)), .completed)
    }

    func testSilentTransitionsAndRepeatedEvents() {
        XCTAssertNil(AgentAlert.transition(from: .working, to: .waiting))
        XCTAssertNil(AgentAlert.transition(from: .starting, to: .working))
        XCTAssertNil(AgentAlert.transition(from: .working, to: .exited(0)))
        XCTAssertNil(AgentAlert.transition(from: .working, to: .paused))
        XCTAssertNil(AgentAlert.transition(from: .yourTurn, to: .needsYou("Reply")))
        XCTAssertNil(AgentAlert.transition(from: .needsYou("Approve"), to: .yourTurn))
        // One alert per wait: a plan review followed by Claude's own notice, a second request, or the answer.
        XCTAssertNil(AgentAlert.transition(from: .needsYou("Review the agent's plan"), to: .permissionRequired("Claude needs your permission")))
        XCTAssertNil(AgentAlert.transition(from: .permissionRequired("Run command"), to: .permissionRequired("Edit file")))
        XCTAssertNil(AgentAlert.transition(from: .permissionRequired("Run command"), to: .needsYou("Continue in the terminal")))
        XCTAssertNil(AgentAlert.transition(from: .permissionRequired("Run command"), to: .yourTurn))
        XCTAssertNil(AgentAlert.transition(from: .permissionRequired("Run command"), to: .working))
        XCTAssertNil(AgentAlert.transition(from: .done(nil), to: .done("Updated summary")))
        XCTAssertNil(AgentAlert.transition(from: .exited(1), to: .exited(2)))
        XCTAssertNil(AgentAlert.transition(from: .ended("Cancelled"), to: .ended("Handed off")))
    }

    func testBannersSayWhatHappenedBrieflyWithMatchingButtons() {
        XCTAssertEqual(AgentAlert.needsYou.message(task: "Implement SK-4505"), "Needs you · Implement SK-4505")
        XCTAssertEqual(AgentAlert.completed.message(task: "Fix the flaky spec\nIt fails on CI only"), "Mission complete · Fix the flaky spec")
        XCTAssertEqual(AgentAlert.failed.message(task: String(repeating: "a", count: 80)), "Stopped unexpectedly · " + String(repeating: "a", count: 59) + "…")
        XCTAssertEqual(AgentAlert.ended.message(task: ""), "Ended")
        XCTAssertEqual(AgentAlert.yourTurn.actions, [.reply, .open])
        XCTAssertEqual(AgentAlert.completed.actions, [.archive, .open])
        XCTAssertEqual(AgentAlert.failed.actions, [.resume, .open])
        XCTAssertEqual(AgentAlert.needsYou.actions, [.open])
        XCTAssertEqual(AgentAlert.notStarted.actions, [.open])
        XCTAssertEqual(AgentAlert.notStarted.sound, "Basso")
        XCTAssertEqual(AgentAlert.notStarted.message(task: "Fix the build"), "Didn't start · Fix the build")
        XCTAssertEqual(AgentAlert.permissionRequired.message(task: "Tidy the build"), "Permission required · Tidy the build")
        XCTAssertEqual(AgentAlert.permissionRequired.actions, [.open], "a banner can't show the command, so it never answers one")
        XCTAssertEqual(AgentAlert.permissionRequired.sound, "Glass")
    }

    func testALaunchThatDidNotStartAlertsOnce() {
        let failure = SessionStatus.notStarted(LaunchFailure(code: 127, output: ["zsh:1: command not found: claude"], resuming: false))
        XCTAssertEqual(AgentAlert.transition(from: .starting, to: failure), .notStarted)
        XCTAssertEqual(AgentAlert.transition(from: .needsYou("Your shell start-up is waiting"), to: failure), .notStarted)
        XCTAssertNil(AgentAlert.transition(from: failure, to: .notStarted(LaunchFailure(code: 127, output: [], resuming: false))))
    }

    @MainActor
    func testPreferencesPersistIndependently() async throws {
        let domain = "AgentNotificationsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let notifications = AgentNotifications(defaults: defaults)
        XCTAssertFalse(notifications.bannersEnabled)
        XCTAssertTrue(notifications.soundsEnabled)
        notifications.bannersEnabled = true
        notifications.soundsEnabled = false
        let restored = AgentNotifications(defaults: defaults)
        XCTAssertTrue(restored.bannersEnabled)
        XCTAssertFalse(restored.soundsEnabled)
    }
}
