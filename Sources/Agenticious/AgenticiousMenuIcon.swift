import AppKit

@MainActor
enum AgenticiousMenuIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setFill()
            let face = NSBezierPath()
            face.move(to: NSPoint(x: 3, y: 12))
            face.line(to: NSPoint(x: 1, y: 10))
            face.line(to: NSPoint(x: 3, y: 9))
            face.curve(to: NSPoint(x: 10, y: 1), controlPoint1: NSPoint(x: 3, y: 4), controlPoint2: NSPoint(x: 6, y: 1))
            face.curve(to: NSPoint(x: 17, y: 9), controlPoint1: NSPoint(x: 14, y: 1), controlPoint2: NSPoint(x: 17, y: 4))
            face.line(to: NSPoint(x: 19, y: 10))
            face.line(to: NSPoint(x: 17, y: 12))
            face.close()
            face.appendOval(in: NSRect(x: 4.5, y: 7, width: 4, height: 4))
            face.appendOval(in: NSRect(x: 11.5, y: 7, width: 4, height: 4))
            let grin = NSBezierPath()
            grin.move(to: NSPoint(x: 6, y: 5.5))
            grin.line(to: NSPoint(x: 14, y: 5.5))
            grin.curve(to: NSPoint(x: 6, y: 5.5), controlPoint1: NSPoint(x: 12, y: 1.5), controlPoint2: NSPoint(x: 8, y: 1.5))
            grin.close()
            face.append(grin)
            face.windingRule = .evenOdd
            face.fill()
            NSBezierPath(ovalIn: NSRect(x: 6, y: 8, width: 1.5, height: 2)).fill()
            NSBezierPath(ovalIn: NSRect(x: 12.5, y: 8, width: 1.5, height: 2)).fill()

            let hat = NSBezierPath(roundedRect: NSRect(x: 5, y: 14, width: 10, height: 5), xRadius: 1, yRadius: 1)
            hat.append(NSBezierPath(roundedRect: NSRect(x: 2, y: 12, width: 16, height: 1), xRadius: 0.5, yRadius: 0.5))
            hat.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Agenticious"
        return image
    }()
}
