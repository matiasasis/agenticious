import SwiftUI

struct ChunkGridLayout: Layout {
    static let cardHeight: CGFloat = 72
    private let minimumWidth: CGFloat = 180
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? minimumWidth
        let frames = frames(count: subviews.count, width: width)
        return CGSize(width: width, height: frames.last?.maxY ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(count: subviews.count, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    func frames(count: Int, width: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let width = width.isFinite ? max(0, width) : CGFloat(count) * (minimumWidth + spacing) - spacing
        let capacity = max(1, min(count, Int((width + spacing) / (minimumWidth + spacing))))
        let rowCount = (count + capacity - 1) / capacity
        let baseCount = count / rowCount
        let extra = count % rowCount

        return (0..<rowCount).flatMap { row in
            let columns = baseCount + (row < extra ? 1 : 0)
            let cardWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            return (0..<columns).map { column in
                CGRect(x: CGFloat(column) * (cardWidth + spacing), y: CGFloat(row) * (Self.cardHeight + spacing),
                       width: cardWidth, height: Self.cardHeight)
            }
        }
    }
}
