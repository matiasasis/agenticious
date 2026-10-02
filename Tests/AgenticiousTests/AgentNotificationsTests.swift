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
    }

    func testSilentTransitionsAndRepeatedEvents() {
        XCTAssertNil(AgentAlert.transition(from: .working, to: .waiting))
        XCTAssertNil(AgentAlert.transition(from: .starting, to: .working))
        XCTAssertNil(AgentAlert.transition(from: .working, to: .exited(0)))
        XCTAssertNil(AgentAlert.transition(from: .working, to: .paused))
        XCTAssertNil(AgentAlert.transition(from: .yourTurn, to: .needsYou("Reply")))
        XCTAssertNil(AgentAlert.transition(from: .needsYou("Approve"), to: .yourTurn))
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
