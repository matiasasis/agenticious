import SwiftUI

/// The last inputs started with the selected preset, under Task input. A click puts one back; nothing shows without any.
struct RecentInputsRow: View {
    let inputs: [RecentInput]
    var now = Date()
    let use: (String) -> Void
    let remove: (String) -> Void
    @Environment(\.textScale) private var textScale

    static let lineLimit = 3
    /// The narrowest a box gets before the five wrap: five across the sheet at the normal size, and no more than two
    /// rows at the largest text size in the narrowest sheet.
    static let boxWidth: CGFloat = 140
    static let spacing: CGFloat = 8

    var body: some View {
        if !inputs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("RECENT").scaledFont(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                RecentInputsLayout(minimumWidth: Self.boxWidth * textScale, spacing: Self.spacing) {
                    ForEach(inputs) { input in
                        RecentInputBox(input: input, age: PromptHistoryLog.age(of: input.usedAt, now: now),
                                       use: { use(input.text) }, remove: { remove(input.text) })
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

/// Wraps rather than scrolls, so every box is in view. Five across when they fit; otherwise five split into even rows
/// (3 + 2, not 4 + 1). Boxes keep that width however many there are, so a single input doesn't stretch across.
struct RecentInputsLayout: Layout {
    var minimumWidth: CGFloat
    var spacing: CGFloat = 8
    var slots = PromptHistory.shown

    func columns(for width: CGFloat) -> Int {
        let fit = max(1, Int((width + spacing) / (minimumWidth + spacing)))
        guard fit < slots else { return slots }
        let rows = (slots + fit - 1) / fit
        return (slots + rows - 1) / rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? CGFloat(slots) * (minimumWidth + spacing) - spacing
        return CGSize(width: width, height: frames(subviews, width: width).last?.maxY ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
    }

    /// Each row is as tall as its tallest box, which lines the boxes up whatever their text.
    private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        let columns = columns(for: width)
        let boxWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let row = subviews[start..<min(start + columns, subviews.count)]
            let height = row.map { $0.sizeThatFits(ProposedViewSize(width: boxWidth, height: nil)).height }.max() ?? 0
            frames += (0..<row.count).map { CGRect(x: CGFloat($0) * (boxWidth + spacing), y: y, width: boxWidth, height: height) }
            y += height + spacing
        }
        return frames
    }
}

private struct RecentInputBox: View {
    let input: RecentInput
    let age: String
    let use: () -> Void
    let remove: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: use) {
            VStack(alignment: .leading, spacing: 6) {
                // Verbatim: an input is shown as typed, fences and all, not as Markdown.
                Text(verbatim: input.text)
                    .scaledFont(.system(size: 12))
                    .lineLimit(RecentInputsRow.lineLimit, reservesSpace: true)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(age).scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgenticiousStyle.violet.opacity(isHovered ? 0.7 : 0.25)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preview), \(age)")
        .accessibilityHint("Puts this into Task input")
        // The × only shows on hover; this keeps removal in reach of VoiceOver.
        .accessibilityAction(named: "Remove from recent", remove)
        // Beside the age line, where it covers no text. Only there on hover, so it is never an invisible Tab stop.
        .overlay(alignment: .bottomTrailing) {
            if isHovered {
                Button("Remove from recent", systemImage: "xmark.circle.fill", action: remove)
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .scaledFont(.callout).foregroundStyle(.white, AgenticiousStyle.violet.opacity(0.8))
                    .padding(4)
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu { Button("Remove from recent", action: remove) }
        .help(preview)
    }

    /// Tooltip and VoiceOver get a short form: a pasted log would otherwise fill the screen or take minutes to hear.
    private var preview: String {
        let head = input.text.split(separator: "\n", maxSplits: 8, omittingEmptySubsequences: false).prefix(8).joined(separator: "\n")
        let short = String(head.prefix(300))
        return short.count < input.text.count ? short + "…" : short
    }
}
