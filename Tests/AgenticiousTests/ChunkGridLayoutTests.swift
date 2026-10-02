import XCTest
@testable import Agenticious

final class ChunkGridLayoutTests: XCTestCase {
    private let layout = ChunkGridLayout()

    func testFiveStepsFillOneWideRow() {
        let frames = layout.frames(count: 5, width: 1100)
        XCTAssertEqual(frames.count, 5)
        XCTAssertTrue(frames.allSatisfy { $0.minY == 0 && $0.height == 56 })
        XCTAssertEqual(frames.last!.maxX, 1100, accuracy: 0.001)
    }

    func testFiveStepsBalanceIntoThreeAndTwoEvenWhenFourFit() {
        for width: CGFloat in [556, 744, 900] {
            let frames = layout.frames(count: 5, width: width)
            let rows = Dictionary(grouping: frames, by: \.minY).sorted { $0.key < $1.key }.map(\.value)
            XCTAssertEqual(rows.map(\.count), [3, 2])
            for row in rows {
                XCTAssertEqual(row.first!.minX, 0)
                XCTAssertEqual(row.last!.maxX, width, accuracy: 0.001)
            }
        }
    }

    func testNarrowWidthsPreserveOrderAndFillEveryRow() {
        let frames = layout.frames(count: 5, width: 368)
        XCTAssertEqual(frames.map(\.minY), [0, 0, 64, 64, 128])
        XCTAssertEqual(frames.last!.width, 368)
        let singleColumn = layout.frames(count: 5, width: 160)
        XCTAssertEqual(singleColumn.map(\.minY), [0, 64, 128, 192, 256])
        XCTAssertTrue(singleColumn.allSatisfy { $0.width == 160 })
    }

    func testDifferentCountsNeverLeaveGapsOrOverflow() {
        for count in 1...12 {
            for width: CGFloat in [0, 180, 367, 368, 555, 556, 932, 1400] {
                let frames = layout.frames(count: count, width: width)
                XCTAssertEqual(frames.count, count)
                let rows = Dictionary(grouping: frames, by: \.minY).values
                let sizes = rows.map(\.count)
                XCTAssertLessThanOrEqual(sizes.max()! - sizes.min()!, 1)
                for row in rows {
                    XCTAssertEqual(row.first!.minX, 0)
                    XCTAssertEqual(row.last!.maxX, width, accuracy: 0.001)
                    for pair in zip(row, row.dropFirst()) {
                        XCTAssertEqual(pair.1.minX - pair.0.maxX, 8, accuracy: 0.001)
                    }
                }
            }
        }
        XCTAssertTrue(layout.frames(count: 0, width: 800).isEmpty)
        XCTAssertTrue(layout.frames(count: 5, width: .infinity).allSatisfy { $0.width.isFinite })
    }
}
