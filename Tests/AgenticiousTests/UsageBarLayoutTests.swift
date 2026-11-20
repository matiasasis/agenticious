import SwiftUI
import XCTest
@testable import Agenticious

@MainActor
final class UsageBarLayoutTests: XCTestCase {
    /// Codex's model quota takes two lines; Claude's badge still matches its height, side by side.
    func testProviderBadgesShareOneHeight() throws {
        defer { UserDefaults.standard.removeObject(forKey: "claudeRateLimits") }
        let usage = UsageMonitor()
        usage.recordClaudeRateLimits(["five_hour": ["used_percentage": 12.0], "seven_day": ["used_percentage": 65.0]])
        usage.recordCodexModelQuotas(CodexModelQuotaReading(quotas: [CodexModelQuota(id: "gpt-6-astra", available: true, availableAt: nil)],
                                                            checkedAt: Date()))
        let renderer = ImageRenderer(content: UsageBar().environmentObject(usage).padding(10).background(Color.black)
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let rows = try XCTUnwrap(Self.paintedRows(in: image))
        // Columns just inside the first badge's left edge and the last badge's right edge.
        let first = try XCTUnwrap(rows.firstIndex { $0 != nil }) + 3
        let last = try XCTUnwrap(rows.lastIndex { $0 != nil }) - 3
        let left = try XCTUnwrap(rows[first]), right = try XCTUnwrap(rows[last])
        XCTAssertEqual(left.lowerBound, right.lowerBound, accuracy: 1, "tops: Claude \(left), Codex \(right)")
        XCTAssertEqual(left.upperBound, right.upperBound, accuracy: 1, "bottoms: Claude \(left), Codex \(right)")
    }

    /// For each column, the rows from the first to the last pixel that isn't the black backdrop.
    private static func paintedRows(in image: CGImage) -> [ClosedRange<Int>?]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<width).map { x in
            let painted = (0..<height).filter { y in
                let i = (y * width + x) * 4
                return Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) > 30
            }
            guard let top = painted.first, let bottom = painted.last else { return nil }
            return top...bottom
        }
    }
}
