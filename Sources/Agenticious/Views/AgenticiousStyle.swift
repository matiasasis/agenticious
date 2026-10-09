import SwiftUI

enum AgenticiousStyle {
    static func usageColor(usedPercent: Double) -> Color {
        usedPercent >= 90 ? .red : usedPercent >= 70 ? .orange : lime
    }

    static let ink = Color(red: 0.055, green: 0.045, blue: 0.09)
    static let panel = Color(red: 0.10, green: 0.08, blue: 0.15)
    static let lime = Color(red: 0.72, green: 0.95, blue: 0.38)
    static let violet = Color(red: 0.76, green: 0.49, blue: 0.96)
    static let coral = Color(red: 0.98, green: 0.56, blue: 0.50)
}

struct ControlRoomHero: View {
    let isEmpty: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("THE CONTROL ROOM", systemImage: "sparkles")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AgenticiousStyle.lime)
            Text(isEmpty ? "Let's raise\nsome agents." : "Beautiful chaos.\nUnder control.")
                .font(.system(size: 36, weight: .black, design: .rounded))
                .tracking(-1.2)
                .fixedSize(horizontal: true, vertical: false)
            Text("Big ideas. Strange powers. Work getting done.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [AgenticiousStyle.panel, AgenticiousStyle.violet.opacity(0.16)],
                           startPoint: .leading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(AgenticiousStyle.violet.opacity(0.35)))
    }
}

struct DashboardMetric: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(value)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 7).padding(.vertical, 7)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.25)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(title.lowercased())")
    }
}

struct AgenticiousButtonStyle: ButtonStyle {
    var isPrimary = true
    var isCompact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, isCompact ? 10 : 18)
            .padding(.vertical, isCompact ? 6 : 11)
            .foregroundStyle(isPrimary ? AgenticiousStyle.ink : Color.primary)
            .background(isPrimary ? AgenticiousStyle.lime : AgenticiousStyle.panel, in: Capsule())
            .overlay(Capsule().stroke(isPrimary ? Color.clear : AgenticiousStyle.violet.opacity(0.4)))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// Small secondary actions beside the status pill, like Archive. A tint colours the text and fill; none is plain gray.
struct PillButtonStyle: ButtonStyle {
    var tint: Color?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .background((tint ?? .gray).opacity(0.15), in: Capsule())
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}
