import AppKit

/// What the Stream Deck plugin (`streamdeck/`) asks over the loopback server: the presets to lay out on the deck,
/// and the floating Summon window on the one whose key was pressed.
@MainActor
enum StreamDeck {
    private struct Key: Encodable {
        let id: String
        let name: String
        let image: String
    }

    /// Nil for anything that isn't the plugin's to ask. Presets come in their arranged order, not by use, so a
    /// preset keeps its key on the deck.
    static func answer(_ request: LocalRequest, presets: [TaskTemplate], summon: (TaskTemplate) -> Bool) -> Data? {
        switch (request.method, request.path.first, request.path.count) {
        case ("GET", "presets", 1):
            return try? JSONEncoder().encode(["presets": presets.map { Key(id: $0.id, name: $0.name, image: keyImage(for: $0)) }])
        case ("POST", "summon", 2):
            // Not ok for a preset that's gone, and when the window couldn't open: the deck then stays on its page.
            return try? JSONEncoder().encode(["ok": presets.first { $0.id == request.path[1] }.map(summon) ?? false])
        default:
            return nil
        }
    }

    private static var images: [String: String] = [:]

    /// The plugin asks every couple of seconds; a key is drawn once per name and symbol.
    static func keyImage(for preset: TaskTemplate) -> String {
        let key = preset.symbol + "\n" + preset.name
        if let image = images[key] { return image }
        let image = "data:image/png;base64," + (keyPNG(name: preset.name, symbol: preset.symbol)?.base64EncodedString() ?? "")
        images[key] = image
        return image
    }

    static let keySize = 144

    /// A deck key that looks like the preset's card in Customize: a panel with the violet edge, the name in lime
    /// across the top as on the deck's other keys, and the preset's symbol in its lime tile under it. Drawn here because SF Symbols only exist on this side.
    static func keyPNG(name: String, symbol: String) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: keySize, pixelsHigh: keySize, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context

        let (lime, violet) = (NSColor(AgenticiousStyle.lime), NSColor(AgenticiousStyle.violet))
        let bounds = NSRect(x: 0, y: 0, width: keySize, height: keySize)
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 22, yRadius: 22)
        NSGradient(starting: NSColor(AgenticiousStyle.panel), ending: violet.blended(withFraction: 0.78, of: NSColor(AgenticiousStyle.panel)) ?? violet)?
            .draw(in: card, angle: -35)
        violet.withAlphaComponent(0.45).setStroke()
        card.lineWidth = 2
        card.stroke()

        // One line when the name fits, shrinking a little first; two smaller ones when it doesn't.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = -1
        func label(_ size: CGFloat) -> NSAttributedString {
            let base = NSFont.systemFont(ofSize: size, weight: .bold)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
            return NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: lime, .paragraphStyle: paragraph])
        }
        let width = bounds.width - 16
        let text = [18, 16].map(label).first { $0.size().width <= width } ?? label(15)
        let height = min(text.boundingRect(with: NSSize(width: width, height: 100), options: .usesLineFragmentOrigin).height, 40)
        // Centred in the space above the tile, whether it took one line or two.
        text.draw(with: NSRect(x: 8, y: bounds.height - 32 - height / 2, width: width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        let tile = NSRect(x: bounds.midX - 34, y: 14, width: 68, height: 68)
        lime.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 18, yRadius: 18).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: 34, weight: .medium).applying(.init(paletteColors: [lime]))
        let glyph = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil))?
            .withSymbolConfiguration(configuration)
        if let glyph {
            let area = tile.insetBy(dx: 10, dy: 10)
            let scale = min(1, area.width / glyph.size.width, area.height / glyph.size.height)
            let size = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
            glyph.draw(in: NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height))
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
