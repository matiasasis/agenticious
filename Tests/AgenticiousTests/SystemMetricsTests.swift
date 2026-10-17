import XCTest
@testable import Agenticious

final class SystemMetricsTests: XCTestCase {
    func testCPUUsesDeltasAndIncludesSystemAndNiceWork() throws {
        let before = CPUTicks(user: 10, system: 20, idle: 30, nice: 40)
        let after = CPUTicks(user: 20, system: 40, idle: 90, nice: 50)
        XCTAssertEqual(try XCTUnwrap(after.utilization(since: before)), 0.4, accuracy: 0.001)
        XCTAssertNil(before.utilization(since: before))
    }

    func testCPUCountersCanWrapWithoutOverflowing() throws {
        let before = CPUTicks(user: .max - 4, system: 0, idle: 50, nice: 0)
        let after = CPUTicks(user: 5, system: 0, idle: 60, nice: 0)
        XCTAssertEqual(try XCTUnwrap(after.utilization(since: before)), 0.5, accuracy: 0.001)
    }

    func testMissingAndOutOfRangeMetricsStayHonest() {
        var metrics = SystemMetrics()
        XCTAssertNil(metrics.memoryFraction)
        XCTAssertNil(metrics.diskFraction)
        XCTAssertEqual(metrics.pressureLabel, "Pressure unavailable")
        XCTAssertEqual(SystemMetrics.bytes(nil), "Unavailable")
        metrics.memoryUsed = 200
        metrics.memoryTotal = 100
        XCTAssertEqual(metrics.memoryFraction, 1)
        metrics.diskFree = 200
        metrics.diskTotal = 100
        XCTAssertEqual(metrics.diskFraction, 0)
        metrics.diskTotal = 0
        XCTAssertNil(metrics.diskFraction)
        metrics.pressure = 4
        XCTAssertEqual(metrics.pressureLabel, "High pressure")
    }

    func testNativeSamplerReportsMemoryAndDiskAndPrimesCPU() async throws {
        let reader = SystemMetricsReader()
        let first = await reader.read()
        XCTAssertNil(first.cpu)
        XCTAssertGreaterThan(try XCTUnwrap(first.memoryUsed), 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(first.memoryUsed), first.memoryTotal)
        XCTAssertGreaterThan(try XCTUnwrap(first.diskTotal), 0)
        try await Task.sleep(for: .milliseconds(100))
        let next = await reader.read()
        XCTAssertTrue((0...1).contains(try XCTUnwrap(next.cpu)))
        await reader.reset()
        let reset = await reader.read()
        XCTAssertNil(reset.cpu)
    }

    @MainActor
    func testSystemSamplingStopsWhenItsVisibilityTaskIsCancelled() async throws {
        let monitor = SystemMetricsMonitor()
        let task = Task { await monitor.sampleWhileVisible() }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await task.value
        XCTAssertGreaterThan(try XCTUnwrap(monitor.current.memoryUsed), 0)
        let samples = monitor.cpuHistory.count
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(monitor.cpuHistory.count, samples)
    }

}
