import AppKit
import SwiftUI

extension View {
    func linkCursor() -> some View { background(LinkCursorRegion()) }
}

private struct LinkCursorRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { LinkCursorView() }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.window?.invalidateCursorRects(for: nsView) }
}

private final class LinkCursorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        addVisibleLinkCursor(for: bounds)
    }
}

struct LinkedMarkdownText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> LinkTextView {
        let view = LinkTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.linkTextAttributes = [.foregroundColor: NSColor(AgenticiousStyle.violet), .cursor: NSCursor.pointingHand]
        return view
    }

    func updateNSView(_ view: LinkTextView, context: Context) {
        let content = Self.attributedText(text)
        if view.textStorage?.isEqual(to: content) != true {
            view.textStorage?.setAttributedString(content)
            view.window?.invalidateCursorRects(for: view)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LinkTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return nsView.fittingSize(width: width)
    }

    static func attributedText(_ text: String) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let value = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 13)
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if let url = run.link {
                attributes[.link] = url
                attributes[.foregroundColor] = NSColor(AgenticiousStyle.violet)
                attributes[.cursor] = NSCursor.pointingHand
            }
            result.append(NSAttributedString(string: value, attributes: attributes))
        }
        return result
    }
}

final class LinkTextView: NSTextView {
    /// As wide as the longest laid-out line, so short text doesn't stretch to `width`. Lays out a copy because
    /// the view's own container tracks its frame, which SwiftUI hasn't sized yet on the first pass.
    func fittingSize(width: CGFloat) -> CGSize? {
        guard let text = textStorage else { return nil }
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        let storage = NSTextStorage(attributedString: text)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: min(width, ceil(used.width)), height: max(17, ceil(used.height)))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in linkRects() { addVisibleLinkCursor(for: rect) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    func linkRects() -> [NSRect] {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return [] }
        layout.ensureLayout(for: container)
        var rects: [NSRect] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                rects.append(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
            }
        }
        return rects
    }
}

extension NSView {
    func addVisibleLinkCursor(for rect: NSRect) {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return }
        let clipped = rect.intersection(visibleRect)
        guard !clipped.isEmpty, clipped.origin.x.isFinite, clipped.origin.y.isFinite,
              clipped.width.isFinite, clipped.height.isFinite else { return }
        addCursorRect(clipped, cursor: .pointingHand)
    }
}
