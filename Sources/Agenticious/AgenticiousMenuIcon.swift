import AppKit

/// The wordmark's "A" (SF Pro Rounded, black) with a spark: solid shapes that stay crisp at menu bar size.
@MainActor
enum AgenticiousMenuIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            let base = NSFont.systemFont(ofSize: 16, weight: .black)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 16) } ?? base
            let letter = NSAttributedString(string: "A", attributes: [.font: font, .foregroundColor: NSColor.black])
            let size = letter.size()
            letter.draw(at: NSPoint(x: bounds.midX - size.width / 2 - 1.5, y: bounds.midY - size.height / 2 - 1 - font.descender / 2))

            NSColor.black.setFill()
            spark(center: NSPoint(x: 15, y: 14.5), radius: 3.2).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Agenticious"
        return image
    }()

    /// A four-point star with pinched sides, like the sparkles used across the app.
    private static func spark(center c: NSPoint, radius r: CGFloat) -> NSBezierPath {
        let pinch = r * 0.28
        let path = NSBezierPath()
        path.move(to: NSPoint(x: c.x, y: c.y + r))
        for (tip, control) in [((r, 0.0), (pinch, pinch)), ((0, -r), (pinch, -pinch)), ((-r, 0), (-pinch, -pinch)), ((0, r), (-pinch, pinch))] {
            let point = NSPoint(x: c.x + tip.0, y: c.y + tip.1)
            let handle = NSPoint(x: c.x + control.0, y: c.y + control.1)
            path.curve(to: point, controlPoint1: handle, controlPoint2: handle)
        }
        path.close()
        return path
    }
}
