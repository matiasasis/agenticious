import SwiftUI
import XCTest
@testable import Agenticious

final class MenuBarContentTests: XCTestCase {
    func testReportedUsageClampsReadingsAndDoesNotInventUsageAfterReset() {
        let now = Date()
        func limit(_ used: Double, reset: Date? = nil) -> UsageLimit {
            UsageLimit(usedPercent: used, windowMinutes: 300, resetsAt: reset)
        }
        XCTAssertEqual(limit(24).reportedUsedPercent(at: now), 24)
        XCTAssertEqual(limit(120).reportedUsedPercent(at: now), 100)
        XCTAssertEqual(limit(-10).reportedUsedPercent(at: now), 0)
        XCTAssertNil(limit(.nan).reportedUsedPercent(at: now))
        XCTAssertNil(limit(90, reset: now).reportedUsedPercent(at: now))
        XCTAssertNil(limit(90, reset: now.addingTimeInterval(-1)).reportedUsedPercent(at: now))
        XCTAssertEqual(limit(90, reset: now.addingTimeInterval(1)).reportedUsedPercent(at: now), 90)
    }

    @MainActor
    func testMenuRendersBothProvidersInOneBoundedPanel() throws {
        let monitor = UsageMonitor()
        let view = NSHostingView(rootView: MenuBarContent().environmentObject(monitor))
        view.frame.size = view.fittingSize
        XCTAssertEqual(view.frame.width, 400)
        XCTAssertLessThan(view.frame.height, 680)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["MENU_PANEL_SNAPSHOT_PATH"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    func testLimitRowsRenderWithinMenuWidth() throws {
        let now = Date()
        let rows = VStack(spacing: 20) {
            MenuLimitRow(limit: UsageLimit(usedPercent: 24, windowMinutes: 300,
                                          resetsAt: now.addingTimeInterval(3600)), date: now)
            MenuLimitRow(limit: UsageLimit(usedPercent: 96, windowMinutes: 10080,
                                          resetsAt: now.addingTimeInterval(86400)), date: now)
            MenuLimitRow(limit: UsageLimit(usedPercent: 80, windowMinutes: 300,
                                          resetsAt: now.addingTimeInterval(-1)), date: now)
        }.padding(20).frame(width: 364)
        let view = NSHostingView(rootView: rows)
        view.frame.size = view.fittingSize
        XCTAssertEqual(view.frame.width, 364)
        XCTAssertLessThan(view.frame.height, 300)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["MENU_SNAPSHOT_PATH"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
