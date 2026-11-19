import AppKit
import SwiftUI

/// A font written the way `Font` is (`.caption`, `.callout.weight(.semibold)`, `.system(size: 26, weight: .bold)`)
/// that follows the app's text size. At scale 1 it is exactly the `Font` the same expression gives.
struct ScaledFont: Hashable {
    private enum Base: Hashable {
        case style(Font.TextStyle, design: Font.Design?)
        case size(CGFloat, weight: Font.Weight?, design: Font.Design?)
        case custom(String, size: CGFloat)
    }

    private enum Change: Hashable {
        case weight(Font.Weight), bold, italic, monospaced, monospacedDigit
    }

    private let base: Base
    private var changes: [Change] = []

    static let largeTitle = system(.largeTitle)
    static let title2 = system(.title2)
    static let title3 = system(.title3)
    static let headline = system(.headline)
    static let subheadline = system(.subheadline)
    static let body = system(.body)
    static let callout = system(.callout)
    static let caption = system(.caption)
    static let caption2 = system(.caption2)

    static func system(_ style: Font.TextStyle, design: Font.Design? = nil) -> ScaledFont {
        ScaledFont(base: .style(style, design: design))
    }

    static func system(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> ScaledFont {
        ScaledFont(base: .size(size, weight: weight, design: design))
    }

    static func custom(_ name: String, size: CGFloat) -> ScaledFont {
        ScaledFont(base: .custom(name, size: size))
    }

    func weight(_ weight: Font.Weight) -> ScaledFont { adding(.weight(weight)) }
    func bold() -> ScaledFont { adding(.bold) }
    func italic() -> ScaledFont { adding(.italic) }
    func monospaced() -> ScaledFont { adding(.monospaced) }
    func monospacedDigit() -> ScaledFont { adding(.monospacedDigit) }

    private func adding(_ change: Change) -> ScaledFont {
        var font = self
        font.changes.append(change)
        return font
    }

    func font(_ scale: CGFloat) -> Font {
        changes.reduce(unchanged(scale)) { font, change in
            switch change {
            case let .weight(weight): font.weight(weight)
            case .bold: font.bold()
            case .italic: font.italic()
            case .monospaced: font.monospaced()
            case .monospacedDigit: font.monospacedDigit()
            }
        }
    }

    private func unchanged(_ scale: CGFloat) -> Font {
        switch base {
        case let .style(style, design):
            return scale == 1 ? .system(style, design: design) : Font(Self.systemFont(style, design: design, scale: scale))
        case let .size(size, weight, design):
            return .system(size: size * scale, weight: weight, design: design)
        case let .custom(name, size):
            return .custom(name, size: size * scale)
        }
    }

    /// The AppKit font behind a text style, resized. SwiftUI draws the style with this very font, so resizing it
    /// keeps the style's weight, its line spacing and what `bold()` means for it (semibold for most styles).
    static func systemFont(_ style: Font.TextStyle, design: Font.Design? = nil, scale: CGFloat) -> NSFont {
        let font = NSFont.preferredFont(forTextStyle: style.appKit)
        let size = font.pointSize * scale
        guard let design, let descriptor = font.fontDescriptor.withDesign(design.appKit) else { return font.withSize(size) }
        return NSFont(descriptor: descriptor, size: size) ?? font.withSize(size)
    }
}

private extension Font.TextStyle {
    var appKit: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

private extension Font.Design {
    var appKit: NSFontDescriptor.SystemDesign {
        switch self {
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        default: .default
        }
    }
}

extension NSFont {
    /// For AppKit text. The same font at the normal size, not a rebuilt one.
    func scaled(_ scale: CGFloat) -> NSFont { scale == 1 ? self : withSize(pointSize * scale) }
}

extension View {
    /// `font(_:)` that follows the app's text size.
    func scaledFont(_ font: ScaledFont) -> some View { modifier(ScaledFontModifier(font: font)) }

    /// `frame(width:height:alignment:)` for a box that text or a symbol has to fit in: it grows with the text.
    func scaledFrame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(ScaledFrame(width: width, height: height, alignment: alignment))
    }

    /// `frame(minWidth:…maxHeight:alignment:)` with every limit growing with the text.
    func scaledFrame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
                     minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
                     alignment: Alignment = .center) -> some View {
        modifier(ScaledFlexibleFrame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth,
                                     minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight, alignment: alignment))
    }
}

extension Text {
    /// For text that has to stay `Text`: joined with `+`, or the label of a menu or pop-up button, which only
    /// takes a font set on the text itself. The scale comes from `@Environment(\.textScale)`.
    func scaledFont(_ font: ScaledFont, _ scale: CGFloat) -> Text { self.font(font.font(scale)) }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.textScale) private var scale
    let font: ScaledFont

    func body(content: Content) -> some View { content.font(font.font(scale)) }
}

private struct ScaledFrame: ViewModifier {
    @Environment(\.textScale) private var scale
    let width: CGFloat?
    let height: CGFloat?
    let alignment: Alignment

    func body(content: Content) -> some View {
        content.frame(width: width.map { $0 * scale }, height: height.map { $0 * scale }, alignment: alignment)
    }
}

private struct ScaledFlexibleFrame: ViewModifier {
    @Environment(\.textScale) private var scale
    let minWidth: CGFloat?
    let idealWidth: CGFloat?
    let maxWidth: CGFloat?
    let minHeight: CGFloat?
    let idealHeight: CGFloat?
    let maxHeight: CGFloat?
    let alignment: Alignment

    func body(content: Content) -> some View {
        content.frame(minWidth: minWidth.map { $0 * scale }, idealWidth: idealWidth.map { $0 * scale }, maxWidth: maxWidth.map { $0 * scale },
                      minHeight: minHeight.map { $0 * scale }, idealHeight: idealHeight.map { $0 * scale }, maxHeight: maxHeight.map { $0 * scale },
                      alignment: alignment)
    }
}
