import Foundation
import Combine

struct InstalledSkill: Identifiable, Hashable {
    let url: URL
    let name: String
    let summary: String
    let source: String
    let isEditable: Bool
    var id: String { url.path }
}

struct SkillSource {
    let url: URL
    let label: String
    var isEditable = true
}

struct SkillScanResult {
    var skills: [InstalledSkill] = []
    var issues: [String] = []
}

struct SkillScanner {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }

    func sources(projectPath: String?, extraPaths: [String]) -> [SkillSource] {
        let codex = codexHome ?? home.appendingPathComponent(".codex")
        var sources = [
            SkillSource(url: home.appendingPathComponent(".agents/skills"), label: "Personal · Shared"),
            SkillSource(url: codex.appendingPathComponent("skills/.system"), label: "System · Codex", isEditable: false),
            SkillSource(url: codex.appendingPathComponent("skills"), label: "Personal · Codex"),
            SkillSource(url: URL(fileURLWithPath: "/etc/codex/skills"), label: "Admin · Codex", isEditable: false),
            SkillSource(url: home.appendingPathComponent(".claude/skills"), label: "Personal · Claude"),
            SkillSource(url: codex.appendingPathComponent("plugins/cache"), label: "Plugin cache · Codex", isEditable: false),
            SkillSource(url: home.appendingPathComponent(".claude/plugins/cache"), label: "Plugin cache · Claude", isEditable: false)
        ]
        if let projectPath {
            var directory = URL(fileURLWithPath: projectPath).standardizedFileURL
            while directory.path != "/" {
                for folder in [".agents/skills", ".codex/skills", ".claude/skills"] {
                    sources.append(SkillSource(url: directory.appendingPathComponent(folder), label: "Project · \(directory.lastPathComponent)"))
                }
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { break }
                directory.deleteLastPathComponent()
            }
        }
        sources += extraPaths.map { SkillSource(url: URL(fileURLWithPath: $0), label: "Added folder") }
        return sources
    }

    func scan(sources: [SkillSource]) -> SkillScanResult {
        var result = SkillScanResult()
        var visited = Set<String>()
        for source in sources {
            walk(source.url, source: source, depth: 0, visited: &visited, result: &result)
        }
        result.skills.sort { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
        return result
    }

    private func walk(_ url: URL, source: SkillSource, depth: Int, visited: inout Set<String>, result: inout SkillScanResult) {
        guard depth < 12, !Task<Never, Never>.isCancelled else { return }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard visited.insert(canonical.path).inserted else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        let skillURL = canonical.appendingPathComponent("SKILL.md")
        do {
            if FileManager.default.fileExists(atPath: skillURL.path) {
                let document = try SkillDocument.read(skillURL)
                result.skills.append(InstalledSkill(url: skillURL, name: document.name ?? canonical.lastPathComponent,
                                                   summary: document.summary ?? "No description provided.",
                                                   source: source.label, isEditable: source.isEditable))
                return
            }
            let children = try FileManager.default.contentsOfDirectory(at: canonical, includingPropertiesForKeys: nil)
            for child in children where ![".git", "node_modules", "scripts", "assets", "references", ".build"].contains(child.lastPathComponent) {
                walk(child, source: source, depth: depth + 1, visited: &visited, result: &result)
            }
        } catch {
            result.issues.append("\(url.path): \(error.localizedDescription)")
        }
    }
}

@MainActor
final class SkillCatalog: ObservableObject {
    @Published private(set) var skills: [InstalledSkill] = []
    @Published private(set) var issues: [String] = []
    @Published private(set) var isLoading = false
    private var generation = UUID()

    func refresh(projectPath: String?, extraPaths: [String]) async {
        let request = UUID()
        generation = request
        isLoading = true
        let scanner = SkillScanner()
        let sources = scanner.sources(projectPath: projectPath, extraPaths: extraPaths)
        let result = await Task.detached(priority: .userInitiated) { scanner.scan(sources: sources) }.value
        guard generation == request, !Task.isCancelled else { return }
        skills = result.skills
        issues = result.issues
        isLoading = false
    }
}

struct SkillDocument {
    let text: String
    var name: String? { metadata("name") }
    var summary: String? { metadata("description") }

    static func read(_ url: URL) throws -> SkillDocument {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw ConfigurationError("Skill files must be smaller than 1 MB.") }
        return SkillDocument(text: try String(contentsOf: url, encoding: .utf8))
    }

    private func metadata(_ key: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return nil }
        guard let index = lines[1..<end].firstIndex(where: { $0.hasPrefix("\(key):") }) else { return nil }
        let scalar = String(lines[index].dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if scalar.hasPrefix("|") || scalar.hasPrefix(">") || scalar.isEmpty {
            let continuation = lines[(index + 1)..<end].prefix { $0.isEmpty || $0.first?.isWhitespace == true }
            let value = continuation.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: scalar.hasPrefix("|") ? "\n" : " ")
            return value.isEmpty ? nil : value
        }
        if scalar.hasPrefix("\""), let data = scalar.data(using: .utf8), let value = try? JSONDecoder().decode(String.self, from: data) { return value }
        if scalar.hasPrefix("'"), scalar.hasSuffix("'") { return String(scalar.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        return scalar.isEmpty ? nil : scalar
    }
}

@MainActor
final class SkillLocations: ObservableObject {
    @Published private(set) var paths: [String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        paths = defaults.stringArray(forKey: "skillSearchFolders") ?? []
    }

    func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !paths.contains(path) else { return }
        paths.append(path)
        defaults.set(paths, forKey: "skillSearchFolders")
    }

    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        defaults.set(paths, forKey: "skillSearchFolders")
    }
}
