import SwiftUI

enum AgenticiousStyle {
    static let ink = Color(red: 0.055, green: 0.045, blue: 0.09)
    static let panel = Color(red: 0.10, green: 0.08, blue: 0.15)
    static let lime = Color(red: 0.72, green: 0.95, blue: 0.38)
    static let violet = Color(red: 0.76, green: 0.49, blue: 0.96)
}

struct ControlRoomHero: View {
    let isEmpty: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            hero(showArtwork: true)
            hero(showArtwork: false)
        }
        .background(AgenticiousStyle.panel)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(AgenticiousStyle.violet.opacity(0.35)))
    }

    private func hero(showArtwork: Bool) -> some View {
        HStack(spacing: 0) {
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

            if showArtwork {
                Image("Mascot", bundle: .module)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 300, height: 300)
                    .clipped()
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.22)
                    ], startPoint: .leading, endPoint: .trailing))
                    .accessibilityHidden(true)
            }
        }
        .background {
            LinearGradient(colors: [AgenticiousStyle.panel, AgenticiousStyle.violet.opacity(0.16)],
                           startPoint: .leading, endPoint: .bottomTrailing)
        }
    }
}

struct DashboardMetric: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(value)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.2)))
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
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .background((tint ?? .gray).opacity(0.15), in: Capsule())
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}
