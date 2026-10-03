import Foundation

/// The block-level Markdown agents write in their replies. The text inside each block stays inline Markdown.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list([MarkdownListItem])
    case quote(String)
    case table(MarkdownTable)
    case code(String)
    /// Box-drawn tables, trees and diagrams: shown as typed, in a monospaced font, so their columns line up.
    case diagram(String)
    case rule
}

struct MarkdownListItem: Equatable {
    var depth: Int
    var marker: String
    var text: String
}

struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }

    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]
}

enum MarkdownBlocks {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
            } else if let fence = fence(trimmed) {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(code.joined(separator: "\n")))
            } else if let heading = heading(line) {
                flushParagraph()
                blocks.append(heading)
                index += 1
            } else if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
            } else if index + 1 < lines.count, let alignments = delimiterRow(lines[index + 1]), cells(line).count == alignments.count {
                flushParagraph()
                index += 2
                blocks.append(.table(MarkdownTable(header: cells(line), alignments: alignments, rows: tableRows(lines, from: &index, columns: alignments.count))))
            } else if let alignments = delimiterRow(line), index + 1 < lines.count, lines[index + 1].contains("|") {
                // A table whose header row was left out, as when part of one is pasted.
                flushParagraph()
                index += 1
                blocks.append(.table(MarkdownTable(header: [], alignments: alignments, rows: tableRows(lines, from: &index, columns: alignments.count))))
            } else if isDiagram(line) {
                flushParagraph()
                var diagram: [String] = []
                while index < lines.count, continuesDiagram(lines[index]) {
                    diagram.append(lines[index])
                    index += 1
                }
                blocks.append(.diagram(diagram.joined(separator: "\n")))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
            } else if listItem(line) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                while index < lines.count {
                    if let item = listItem(lines[index]) {
                        items.append(item)
                    } else if lines[index].hasPrefix("  "), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty, !items.isEmpty {
                        items[items.count - 1].text += "\n" + lines[index].trimmingCharacters(in: .whitespaces)
                    } else if lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                              let next = lines[(index + 1)...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                              listItem(next) != nil {
                        // A blank line between items keeps the list going.
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.list(items))
            } else {
                paragraph.append(line)
                index += 1
            }
        }
        flushParagraph()
        return blocks
    }

    private static func fence(_ trimmed: String) -> String? {
        ["```", "~~~"].first { trimmed.hasPrefix($0) }
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        guard let match = line.firstMatch(of: #/^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/#) else { return nil }
        return .heading(level: match.1.count, text: String(match.2 ?? ""))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        trimmed.wholeMatch(of: #/(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,}/#) != nil
    }

    private static func listItem(_ line: String) -> MarkdownListItem? {
        guard let match = line.firstMatch(of: #/^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(.*)$/#) else { return nil }
        let indent = match.1.replacingOccurrences(of: "\t", with: "    ").count
        let marker = match.2.first?.isNumber == true ? String(match.2.dropLast()) + "." : "•"
        return MarkdownListItem(depth: indent / 2, marker: marker, text: String(match.3))
    }

    private static func tableRows(_ lines: [String], from index: inout Int, columns: Int) -> [[String]] {
        var rows: [[String]] = []
        while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            rows.append(Array((cells(lines[index]) + Array(repeating: "", count: columns)).prefix(columns)))
            index += 1
        }
        return rows
    }

    private static func delimiterRow(_ line: String) -> [MarkdownTable.Alignment]? {
        guard line.contains("-"), line.contains("|") || line.contains(":") else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for cell in cells(line) {
            guard cell.wholeMatch(of: #/:?-+:?/#) != nil else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments.isEmpty ? nil : alignments
    }

    /// Splits a table row on pipes outside `code` spans, ignoring the optional outer pipes. `\|` stays a pipe.
    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row.removeLast() }
        var cells: [String] = []
        var cell = ""
        var inCode = false
        var escaped = false
        for character in row {
            if escaped {
                cell.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                cell.append(character)
            } else if character == "|" && !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func isDiagram(_ line: String) -> Bool {
        line.unicodeScalars.contains { (0x2500...0x257F).contains($0.value) }
            || line.trimmingCharacters(in: .whitespaces).wholeMatch(of: #/\+(?:[-=]+\+)+/#) != nil
    }

    private static func continuesDiagram(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return isDiagram(line) || trimmed.hasPrefix("|") || trimmed.hasPrefix("+")
            || trimmed.unicodeScalars.contains { (0x2190...0x21FF).contains($0.value) || (0x25A0...0x25FF).contains($0.value) }
    }
}
