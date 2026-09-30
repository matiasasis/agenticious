import SwiftUI
import AppKit

/// A text box where ``` starts a code snippet: typing it at the start of a line adds the closing fence, and fenced blocks
/// and `inline code` show in monospace. Smart quotes and dashes are off, so code reaches the agent exactly as typed.
struct SnippetEditor: View {
    @Binding var text: String
    var placeholder = ""
    var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    var minHeight: CGFloat = 40
    var maxHeight: CGFloat = 320
    var focusOnAppear = false

    var body: some View {
        SnippetTextArea(text: $text, font: font, minHeight: minHeight, maxHeight: maxHeight, focusOnAppear: focusOnAppear)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(Font(font)).foregroundStyle(.tertiary)
                        .padding(.leading, SnippetTextArea.inset.width + 5).padding(.top, SnippetTextArea.inset.height)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgenticiousStyle.violet.opacity(0.3)))
    }
}

private struct SnippetTextArea: NSViewRepresentable {
    static let inset = NSSize(width: 5, height: 10)

    @Binding var text: String
    let font: NSFont
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let focusOnAppear: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = FocusingTextView(usingTextLayoutManager: false)
        textView.focusOnAppear = focusOnAppear
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = Self.inset
        textView.insertionPointColor = NSColor(AgenticiousStyle.lime)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        context.coordinator.highlight(textView)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        context.coordinator.highlight(textView)
    }

    /// Grows with its text between the minimum and maximum height, then scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = nsView.documentView as? NSTextView,
              let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height + Self.inset.height * 2
        return CGSize(width: proposal.width ?? 400, height: min(max(height, minHeight), maxHeight))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SnippetTextArea
        private var isClosingFence = false

        init(_ parent: SnippetTextArea) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            highlight(textView)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard !isClosingFence, replacementString == "`",
                  let completion = SnippetFences.completion(in: textView.string, typingBacktickAt: range) else { return true }
            isClosingFence = true
            defer { isClosingFence = false }
            textView.insertText(completion.insertion, replacementRange: range)
            textView.setSelectedRange(NSRange(location: completion.cursor, length: 0))
            return false
        }

        func highlight(_ textView: NSTextView) {
            guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            let code = NSFont.monospacedSystemFont(ofSize: parent.font.pointSize * 0.92, weight: .regular)
            let codeBackground = NSColor(AgenticiousStyle.violet).withAlphaComponent(0.12)
            let styles = SnippetFences.styles(in: storage.string)

            storage.beginEditing()
            storage.setAttributes([.font: parent.font, .foregroundColor: NSColor.labelColor], range: full)
            for range in styles.code { storage.addAttributes([.font: code, .backgroundColor: codeBackground], range: range) }
            for range in styles.fences { storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range) }
            storage.endEditing()
            textView.typingAttributes = [.font: parent.font, .foregroundColor: NSColor.labelColor]
        }
    }
}

/// SwiftUI's focus state doesn't reach an AppKit text view, so the first field takes focus itself once it's in a window.
private final class FocusingTextView: NSTextView {
    var focusOnAppear = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAppear, let window else { return }
        focusOnAppear = false
        DispatchQueue.main.async { window.makeFirstResponder(self) }
    }
}

enum SnippetFences {
    /// When a third backtick opens a fence on an otherwise empty line, the closing fence is added below
    /// and the cursor stays after the opening one, ready for an optional language name.
    static func completion(in text: String, typingBacktickAt range: NSRange) -> (insertion: String, cursor: Int)? {
        let text = text as NSString
        guard range.length == 0 else { return nil }
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: range.location - line.location))
        let after = text.substring(with: NSRange(location: range.location, length: NSMaxRange(line) - range.location))
        guard before == "``", after.trimmingCharacters(in: .newlines).isEmpty,
              !isInsideSnippet(text.substring(to: line.location)) else { return nil }
        return ("`\n```", range.location + 1)
    }

    static func isInsideSnippet(_ text: String) -> Bool {
        text.components(separatedBy: "\n").filter(isFence).count % 2 == 1
    }

    /// Ranges (UTF-16) to show as code, and the fence lines within them to dim.
    static func styles(in text: String) -> (code: [NSRange], fences: [NSRange]) {
        let string = text as NSString
        var code: [NSRange] = []
        var fences: [NSRange] = []
        var openFence: Int?
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            if isFence(string.substring(with: line)) {
                fences.append(line)
                if let start = openFence {
                    code.append(NSRange(location: start, length: NSMaxRange(line) - start))
                    openFence = nil
                } else {
                    openFence = line.location
                }
            } else if openFence == nil {
                code += inlineCode(in: string, line: line)
            }
        }
        if let start = openFence { code.append(NSRange(location: start, length: string.length - start)) }
        return (code, fences)
    }

    private static func isFence<S: StringProtocol>(_ line: S) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    private static let inline = try! NSRegularExpression(pattern: "`[^`\\n]+`")

    private static func inlineCode(in string: NSString, line: NSRange) -> [NSRange] {
        inline.matches(in: string as String, range: line).map(\.range)
    }
}
