import AppKit

@MainActor
enum AgenticiousMenuIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let face = NSBezierPath()
            face.move(to: NSPoint(x: 3, y: 8))
            for point in [NSPoint(x: 0, y: 11), NSPoint(x: 4, y: 11), NSPoint(x: 2, y: 16),
                          NSPoint(x: 7, y: 14), NSPoint(x: 9, y: 18), NSPoint(x: 11, y: 15),
                          NSPoint(x: 16, y: 18), NSPoint(x: 15, y: 13), NSPoint(x: 20, y: 14),
                          NSPoint(x: 17, y: 8)] {
                face.line(to: point)
            }
            face.curve(to: NSPoint(x: 10, y: 0), controlPoint1: NSPoint(x: 17, y: 3), controlPoint2: NSPoint(x: 14, y: 0))
            face.curve(to: NSPoint(x: 3, y: 8), controlPoint1: NSPoint(x: 6, y: 0), controlPoint2: NSPoint(x: 3, y: 3))
            face.close()
            face.appendOval(in: NSRect(x: 4.5, y: 7.5, width: 4, height: 4))
            face.appendOval(in: NSRect(x: 11.5, y: 7.5, width: 4, height: 4))
            let grin = NSBezierPath()
            grin.move(to: NSPoint(x: 5.5, y: 6))
            grin.curve(to: NSPoint(x: 14.5, y: 6), controlPoint1: NSPoint(x: 8, y: 4.5), controlPoint2: NSPoint(x: 12, y: 4.5))
            grin.curve(to: NSPoint(x: 5.5, y: 6), controlPoint1: NSPoint(x: 13, y: 0.5), controlPoint2: NSPoint(x: 7, y: 0.5))
            grin.close()
            face.append(grin)
            face.windingRule = .evenOdd
            NSColor.black.setFill()
            face.fill()
            NSBezierPath(ovalIn: NSRect(x: 6.1, y: 8.4, width: 1.5, height: 1.8)).fill()
            NSBezierPath(ovalIn: NSRect(x: 12.3, y: 8.4, width: 1.5, height: 1.8)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Agenticious"
        return image
    }()
}
