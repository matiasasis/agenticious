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
        XCTAssertNil(AgentAlert.transition(from: .yourTurn, to: .needsYou("Reply")))
        XCTAssertNil(AgentAlert.transition(from: .needsYou("Approve"), to: .yourTurn))
        XCTAssertNil(AgentAlert.transition(from: .done(nil), to: .done("Updated summary")))
        XCTAssertNil(AgentAlert.transition(from: .exited(1), to: .exited(2)))
        XCTAssertNil(AgentAlert.transition(from: .ended("Cancelled"), to: .ended("Handed off")))
    }

    func testBannersCarryTheStatusDetailAndMatchingButtons() {
        XCTAssertEqual(AgentAlert.detail(for: .needsYou("Approve the migration")), "Approve the migration")
        XCTAssertEqual(AgentAlert.detail(for: .ended("Handed off")), "Handed off")
        XCTAssertEqual(AgentAlert.detail(for: .exited(2)), "Exited with code 2.")
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
