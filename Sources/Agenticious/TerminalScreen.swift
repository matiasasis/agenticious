import Foundation
import SwiftTerm

/// The terminal as a person sees it: the visible rows only, whatever the scroll position.
enum TerminalScreen {
    /// Visible rows, top to bottom, with blank cells as spaces and trailing spaces trimmed.
    static func rows(of terminal: Terminal) -> [String] {
        // The buffer ends with the screen: its last `rows` lines are what shows, and the cursor row counts from there.
        let lines = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        return lines.suffix(terminal.rows).map { line in
            var row = String(line.map { $0 == "\0" ? " " : $0 })
            while row.last?.isWhitespace == true { row.removeLast() }
            return row
        }
    }

    /// The cursor's row, cleaned, or nil when it is blank.
    static func cursorRow(of terminal: Terminal, rows: [String]) -> String? {
        let cursor = terminal.getCursorLocation()
        guard rows.indices.contains(cursor.y) else { return nil }
        let row = clean(rows[cursor.y]).trimmingCharacters(in: .whitespaces)
        return row.isEmpty ? nil : row
    }

    /// The text on the cursor's row when the cursor sits right after it, as at a prompt waiting for typing.
    static func textBeforeCursor(of terminal: Terminal, rows: [String]) -> String? {
        let cursor = terminal.getCursorLocation()
        guard rows.indices.contains(cursor.y) else { return nil }
        let row = rows[cursor.y]
        // Columns against characters: a wide character takes two columns, so such a row simply doesn't match.
        guard !row.isEmpty, cursor.x == row.count || cursor.x == row.count + 1 else { return nil }
        let text = clean(row).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// The last lines with text, oldest first, with the blank lines between them: what a failed start left to read.
    static func lastLines(of terminal: Terminal, limit: Int = 8) -> [String] {
        let rows = rows(of: terminal).map { clean($0) }
        guard let last = rows.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return [] }
        return Array(rows[...last].suffix(limit).drop { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// Safe to show as text, and otherwise as printed: control characters become spaces; invisible and
    /// direction-changing marks are dropped; the length is bounded.
    static func clean(_ text: String, limit: Int = 300) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .format, .privateUse, .unassigned, .surrogate: continue
            case .control, .lineSeparator, .paragraphSeparator: result.append(" ")
            default: result.append(scalar)
            }
        }
        var line = String(result)
        while line.last?.isWhitespace == true { line.removeLast() }
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// One line for a status or a sidebar card: runs of spaces collapsed.
    static func oneLine(_ text: String, limit: Int = 120) -> String {
        clean(text, limit: limit).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
