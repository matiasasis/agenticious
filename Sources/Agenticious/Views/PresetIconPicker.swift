import SwiftUI
import AppKit

enum PresetIcons {
    static let groups: [(title: String, symbols: [String])] = [
        ("Magic", ["sparkles", "wand.and.stars", "lightbulb", "brain.head.profile", "atom", "flame", "star", "bolt", "target", "scope"]),
        ("Build", ["hammer", "wrench.and.screwdriver", "screwdriver", "gearshape", "gearshape.2", "cpu", "terminal",
                   "chevron.left.forwardslash.chevron.right", "curlybraces", "function", "cube", "shippingbox",
                   "square.stack.3d.up", "puzzlepiece.extension"]),
        ("Review", ["text.magnifyingglass", "magnifyingglass", "eye", "binoculars", "checkmark.seal", "checklist",
                    "list.bullet.clipboard", "doc.text.magnifyingglass", "hand.thumbsup"]),
        ("Git & ship", ["arrow.triangle.branch", "arrow.triangle.merge", "arrow.triangle.pull", "paperplane",
                        "airplane.departure", "arrow.up.circle", "icloud.and.arrow.up", "flag", "trophy", "crown"]),
        ("Fix & test", ["ladybug", "ant", "stethoscope", "cross.case", "bandage", "testtube.2", "flask",
                        "exclamationmark.triangle", "shield.lefthalf.filled", "lock", "key"]),
        ("Ops & data", ["server.rack", "externaldrive", "cloud", "cylinder.split.1x2", "tablecells", "chart.bar",
                        "chart.pie", "chart.line.uptrend.xyaxis", "gauge.with.dots.needle.67percent", "hare", "tortoise"]),
        ("Write & talk", ["doc.text", "doc.richtext", "book", "books.vertical", "text.book.closed", "pencil",
                          "note.text", "text.bubble", "bubble.left.and.bubble.right", "quote.bubble", "questionmark.bubble",
                          "envelope", "megaphone", "bell"]),
        ("Everything else", ["calendar", "clock", "tray.full", "folder", "archivebox", "trash", "scissors",
                             "arrow.3.trianglepath", "arrow.clockwise", "person.2", "globe", "map", "signpost.right",
                             "paintbrush", "paintpalette", "photo", "iphone", "desktopcomputer", "leaf", "moon.stars",
                             "graduationcap", "figure.run", "heart"]),
    ]

    /// Some symbols are newer than the oldest supported macOS; those are left out rather than drawn blank.
    static func isAvailable(_ symbol: String) -> Bool {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
    }
}

struct PresetIconPicker: View {
    @Binding var symbol: String
    let done: () -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an icon").font(.headline)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(AgenticiousStyle.violet)
                TextField("Search icons", text: $query).textFieldStyle(.plain)
            }
            .padding(10)
            .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgenticiousStyle.violet.opacity(0.3)))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: 8), alignment: .leading, spacing: 8) {
                            ForEach(group.symbols, id: \.self, content: tile)
                        }
                    }
                    if groups.isEmpty {
                        Text("No icons match “\(query)”.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(1)
            }
        }
        .padding(16)
        .frame(width: 400, height: 440)
        .background(AgenticiousStyle.panel)
    }

    private var groups: [(title: String, symbols: [String])] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return PresetIcons.groups.compactMap { group in
            let matches = group.symbols.filter {
                PresetIcons.isAvailable($0) && (query.isEmpty || $0.contains(query) || group.title.lowercased().contains(query))
            }
            return matches.isEmpty ? nil : (group.title, matches)
        }
    }

    private func tile(_ candidate: String) -> some View {
        let isSelected = candidate == symbol
        return Button {
            symbol = candidate
            done()
        } label: {
            Image(systemName: candidate)
                .font(.system(size: 17))
                .frame(width: 40, height: 40)
                .foregroundStyle(isSelected ? AgenticiousStyle.lime : .primary)
                .background(isSelected ? AgenticiousStyle.lime.opacity(0.1) : AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? AgenticiousStyle.lime : AgenticiousStyle.violet.opacity(0.25)))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(candidate)
        .accessibilityLabel(candidate.replacingOccurrences(of: ".", with: " "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
