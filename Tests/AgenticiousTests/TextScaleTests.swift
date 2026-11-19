import AppKit
import SwiftUI
import XCTest
@testable import Agenticious

final class TextScaleTests: XCTestCase {
    func testStoredSizesStayWithinTheSteps() {
        XCTAssertEqual(TextScale.steps, [1.0, 1.1, 1.2, 1.3, 1.4, 1.5])
        XCTAssertEqual(TextScale.range, 1.0...1.5)
        XCTAssertEqual(TextScale.clamped(0), 1)
        XCTAssertEqual(TextScale.clamped(0.5), 1)
        XCTAssertEqual(TextScale.clamped(1.25), 1.25)
        XCTAssertEqual(TextScale.clamped(3), 1.5)
        XCTAssertEqual(TextScale.clamped(-.infinity), 1)
        XCTAssertEqual(TextScale.clamped(.infinity), 1.5)
        XCTAssertEqual(TextScale.clamped(.nan), 1)
    }

    func testBiggerAndSmallerWalkTheStepsAndStopAtTheEnds() {
        XCTAssertEqual(TextScale.steps.map(TextScale.bigger), [1.1, 1.2, 1.3, 1.4, 1.5, 1.5])
        XCTAssertEqual(TextScale.steps.map(TextScale.smaller), [1.0, 1.0, 1.1, 1.2, 1.3, 1.4])
        // Six presses up and six down land exactly on the ends, with no drift.
        XCTAssertEqual((0..<6).reduce(1.0) { size, _ in TextScale.bigger(than: size) }, 1.5)
        XCTAssertEqual((0..<6).reduce(1.5) { size, _ in TextScale.smaller(than: size) }, 1.0)
        // Out of range, between steps, or a step that arithmetic left a hair off.
        XCTAssertEqual(TextScale.bigger(than: 0.2), 1.1)
        XCTAssertEqual(TextScale.smaller(than: 9), 1.4)
        XCTAssertEqual(TextScale.bigger(than: 1.25), 1.3)
        XCTAssertEqual(TextScale.smaller(than: 1.25), 1.2)
        XCTAssertEqual(TextScale.bigger(than: 1.0 + 0.1 + 0.1), 1.3)
        XCTAssertEqual(TextScale.smaller(than: 1.5 - 0.1 - 0.1), 1.2)
    }

    func testSizesAreNamedAsPercentages() {
        XCTAssertEqual(TextScale.steps.map(TextScale.label), ["100%", "110%", "120%", "130%", "140%", "150%"])
        XCTAssertEqual(TextScale.nearestStep(to: 1.26), 1.3)
        XCTAssertEqual(TextScale.nearestStep(to: 7), 1.5)
    }

    func testNativeControlsOnlyGrowOnceTheTextNeedsTheRoom() {
        XCTAssertEqual(TextScale.steps.map(TextScale.controlSize), [.regular, .regular, .large, .large, .extraLarge, .extraLarge])
    }

    /// The normal size must draw exactly what the app drew before the setting existed.
    func testFontsAreUntouchedAtTheNormalSize() {
        XCTAssertEqual(ScaledFont.caption.font(1), Font.caption)
        XCTAssertEqual(ScaledFont.caption2.font(1), Font.caption2)
        XCTAssertEqual(ScaledFont.callout.font(1), Font.callout)
        XCTAssertEqual(ScaledFont.body.font(1), Font.body)
        XCTAssertEqual(ScaledFont.subheadline.font(1), Font.subheadline)
        XCTAssertEqual(ScaledFont.headline.font(1), Font.headline)
        XCTAssertEqual(ScaledFont.title3.font(1), Font.title3)
        XCTAssertEqual(ScaledFont.title2.font(1), Font.title2)
        XCTAssertEqual(ScaledFont.largeTitle.font(1), Font.largeTitle)
        XCTAssertEqual(ScaledFont.callout.weight(.semibold).font(1), Font.callout.weight(.semibold))
        XCTAssertEqual(ScaledFont.title3.bold().font(1), Font.title3.bold())
        XCTAssertEqual(ScaledFont.callout.italic().font(1), Font.callout.italic())
        XCTAssertEqual(ScaledFont.caption.monospaced().font(1), Font.caption.monospaced())
        XCTAssertEqual(ScaledFont.caption.monospacedDigit().font(1), Font.caption.monospacedDigit())
        XCTAssertEqual(ScaledFont.system(.body, design: .monospaced).font(1), Font.system(.body, design: .monospaced))
        XCTAssertEqual(ScaledFont.system(size: 13).font(1), Font.system(size: 13))
        XCTAssertEqual(ScaledFont.system(size: 13, weight: .semibold).font(1), Font.system(size: 13, weight: .semibold))
        XCTAssertEqual(ScaledFont.system(size: 26, weight: .bold, design: .rounded).font(1), Font.system(size: 26, weight: .bold, design: .rounded))
        XCTAssertEqual(ScaledFont.system(size: 12, design: .monospaced).font(1), Font.system(size: 12, design: .monospaced))
        XCTAssertEqual(ScaledFont.system(size: 13).monospacedDigit().font(1), Font.system(size: 13).monospacedDigit())
        XCTAssertEqual(ScaledFont.custom("Menlo", size: 12).font(1), Font.custom("Menlo", size: 12))

        let font = NSFont.systemFont(ofSize: 13)
        XCTAssertTrue(font.scaled(1) === font)
    }

    func testFixedSizesAreMultiplied() {
        XCTAssertEqual(ScaledFont.system(size: 10, weight: .bold, design: .monospaced).font(1.5), Font.system(size: 15, weight: .bold, design: .monospaced))
        XCTAssertEqual(ScaledFont.system(size: 20).monospacedDigit().font(1.5), Font.system(size: 30).monospacedDigit())
        XCTAssertEqual(ScaledFont.custom("Menlo", size: 12).font(1.5), Font.custom("Menlo", size: 18))
        XCTAssertEqual(NSFont.systemFont(ofSize: 13).scaled(1.2).pointSize, 15.6, accuracy: 0.0001)
        XCTAssertEqual(NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).scaled(1.5), NSFont.monospacedSystemFont(ofSize: 18, weight: .regular))
    }

    /// The sizes and weights macOS gives each style, which a larger size has to start from.
    func testTextStylesKeepTheirMacSizeAndWeightWhenScaled() {
        let sizes: [(Font.TextStyle, CGFloat)] = [
            (.largeTitle, 26), (.title, 22), (.title2, 17), (.title3, 15), (.headline, 13), (.body, 13),
            (.callout, 12), (.subheadline, 11), (.footnote, 10), (.caption, 10), (.caption2, 10),
        ]
        for (style, size) in sizes {
            XCTAssertEqual(ScaledFont.systemFont(style, scale: 1).pointSize, size, "\(style)")
            for scale in TextScale.steps {
                XCTAssertEqual(ScaledFont.systemFont(style, scale: scale).pointSize, size * scale, accuracy: 0.0001, "\(style) at \(scale)")
            }
        }
        XCTAssertTrue(ScaledFont.systemFont(.headline, scale: 1.5).fontName.hasSuffix("Bold"))
        XCTAssertTrue(ScaledFont.systemFont(.caption2, scale: 1.5).fontName.hasSuffix("Medium"))
        XCTAssertTrue(ScaledFont.systemFont(.callout, scale: 1.5).fontName.hasSuffix("Regular"))
        XCTAssertTrue(ScaledFont.systemFont(.body, design: .monospaced, scale: 1.5).fontName.contains("Mono"))
        XCTAssertFalse(ScaledFont.systemFont(.body, scale: 1.5).fontName.contains("Mono"))
        XCTAssertNotEqual(ScaledFont.caption.font(1.1), Font.caption)
    }

    @MainActor
    func testTextIsDrawnLargerOnlyBelowAScaledRoot() {
        func width(_ scale: CGFloat) -> CGFloat {
            NSHostingView(rootView: Text("Wiring up the agents").scaledFont(.callout).environment(\.textScale, scale)).fittingSize.width
        }
        XCTAssertEqual(width(1), NSHostingView(rootView: Text("Wiring up the agents").font(.callout)).fittingSize.width)
        XCTAssertEqual(width(1.5), NSHostingView(rootView: Text("Wiring up the agents").font(.system(size: 18))).fittingSize.width)

        let box = NSHostingView(rootView: Color.clear.scaledFrame(width: 26, height: 40).environment(\.textScale, 1.5))
        XCTAssertEqual(box.fittingSize, CGSize(width: 39, height: 60))
        let card = NSHostingView(rootView: Color.clear.scaledFrame(minHeight: 72, maxHeight: 72).environment(\.textScale, 1.5))
        XCTAssertEqual(card.fittingSize.height, 108)
        XCTAssertEqual(NSHostingView(rootView: Color.clear.scaledFrame(width: 26, height: 40)).fittingSize, CGSize(width: 26, height: 40))
    }

    /// What the main window, the menu bar panel and the floating Summon window are each wrapped in.
    @MainActor
    func testAScaledRootFollowsTheStoredSizeWhileItIsOpen() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: TextScale.key)
        defer { defaults.removeObject(forKey: TextScale.key) }
        func width(_ view: some View) -> CGFloat { NSHostingView(rootView: view).fittingSize.width }
        let open = NSHostingView(rootView: HStack { Text("Unstyled"); Text("Styled").scaledFont(.caption) }.textScaled())
        XCTAssertEqual(open.fittingSize.width, width(HStack { Text("Unstyled"); Text("Styled").font(.caption) }))

        for stored in [1.5, 40] {
            defaults.set(stored, forKey: TextScale.key)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(open.fittingSize.width, width(HStack { Text("Unstyled").font(.system(size: 19.5)); Text("Styled").font(.system(size: 15)) }), "\(stored)")
        }
        defaults.set(1.0, forKey: TextScale.key)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(open.fittingSize.width, width(HStack { Text("Unstyled"); Text("Styled").font(.caption) }))
    }

    func testStepCardsGrowWithTheText() {
        let frames = ChunkGridLayout(scale: 1.5).frames(count: 5, width: 1100)
        XCTAssertTrue(frames.allSatisfy { $0.height == 108 })
        // Only the height follows the text: cards still wrap at 180 points, so five stay on one row.
        XCTAssertEqual(Set(frames.map(\.minY)).count, 1)
    }

    @MainActor
    func testRepliesAndTheirCodeFollowTheTextSize() throws {
        let text = LinkedMarkdownText.attributedText("Plain `code`", scale: 1.5)
        let plain = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let code = try XCTUnwrap(text.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(plain.pointSize, 19.5)
        XCTAssertEqual(code.pointSize, 19.5)
        XCTAssertTrue(code.isFixedPitch)
        XCTAssertEqual(LinkedMarkdownText.attributedText("Plain"), LinkedMarkdownText.attributedText("Plain", scale: 1))
    }

    func testPlainCommandEqualsIsRetypedAsCommandPlus() throws {
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 24))
        }
        let retyped = TextScale.commandPlus(for: try key("=", .command))
        XCTAssertEqual(retyped.charactersIgnoringModifiers, "+")
        XCTAssertEqual(retyped.characters, "+")
        XCTAssertEqual(retyped.keyCode, 24)
        XCTAssertEqual(retyped.modifierFlags.intersection([.command, .shift, .option, .control]), .command)
        XCTAssertEqual(TextScale.commandPlus(for: try key("=", [.command, .capsLock])).charactersIgnoringModifiers, "+")
        // Typing "=", and other shortcuts on the same key, are left as they are.
        for other in [try key("=", []), try key("=", [.command, .option]), try key("+", [.command, .shift]), try key("-", .command)] {
            XCTAssertTrue(TextScale.commandPlus(for: other) === other)
        }
    }
}
