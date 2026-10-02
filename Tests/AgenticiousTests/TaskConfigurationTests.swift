import XCTest
@testable import Agenticious

final class TaskConfigurationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testTaskTypePersistsIndependentOfTitleAndPresetEdits() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var template = TaskTemplate(name: "Investigate", symbol: "magnifyingglass")
        let session = AgentSession(task: "Unrelated title", agent: .claude, project: .none, directory: folder,
                                   taskType: TaskType(template: template, input: "  API timeout  ", notes: " Check retries\n"))
        template.symbol = "hammer"
        let database = try SessionDatabase(url: folder.appendingPathComponent("test.sqlite"))
        try database.save(session)
        let restored = try XCTUnwrap(database.load().first)
        XCTAssertEqual(restored.displayedTaskType.name, "Investigate")
        XCTAssertEqual(restored.displayedTaskType.symbol, "magnifyingglass")
        XCTAssertEqual(restored.displayedTaskType.details(for: restored.task), "API timeout\nCheck retries")
    }

    func testOlderTaskMetadataSeparatesKnownPrefixesAndPreservesCustomTitles() throws {
        let type = try JSONDecoder().decode(TaskType.self, from: Data(#"{"name":"Resolve & merge","symbol":"arrow.triangle.merge"}"#.utf8))
        let url = "https://example.slack.com/archives/C0123456789/p1700000000000000"
        XCTAssertEqual(type.details(for: "Resolve & merge: \(url)"), url)
        XCTAssertEqual(type.details(for: "Address comments and merge PR 123"), "123")
        XCTAssertEqual(type.details(for: "Resolve & merge"), "")
        let custom = TaskType(template: .custom)
        XCTAssertEqual(custom.details(for: "Explain https://example.com:8080"), "Explain https://example.com:8080")
        XCTAssertEqual(custom.details(for: "Review PR 123"), "Review PR 123")
    }

    func testTaskDetailsSupportNotesWithoutInputAndEmptyOptionalInput() {
        let template = TaskTemplate.defaults.first { $0.id == "fixCI" }!
        XCTAssertEqual(TaskType(template: template, input: "", notes: " Check retries ").details(for: "Fix CI"), "Check retries")
        XCTAssertEqual(TaskType(template: template, input: " \n").details(for: "Fix CI"), "")
        XCTAssertEqual(TaskType(template: .custom, input: "Review PR 123").details(for: "Review PR 123"), "Review PR 123")
    }

    @MainActor
    func testLegacyTaskTypesAndSchemaMigration() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        do {
            let database = try SessionDatabase(url: url)
            for title in ["Review PRs: 123", "Resolve & merge: 123", "Implement SK-123", "Fix CI 123", "Address comments and merge PR 123", "Explain the code"] {
                try database.save(AgentSession(task: title, agent: .claude, project: .none, directory: folder))
            }
            let legacy = try Database(url: url)
            try legacy.execute("ALTER TABLE sessions DROP COLUMN task_type")
            legacy.schemaVersion = 3
        }
        let sessions = try SessionDatabase(url: url).load()
        let symbols = Dictionary(uniqueKeysWithValues: sessions.map { ($0.task, $0.displayedTaskType.symbol) })
        XCTAssertEqual(symbols["Review PRs: 123"], "text.magnifyingglass")
        XCTAssertEqual(symbols["Resolve & merge: 123"], "arrow.triangle.merge")
        XCTAssertEqual(symbols["Implement SK-123"], "hammer")
        XCTAssertEqual(symbols["Fix CI 123"], "wrench.and.screwdriver")
        XCTAssertEqual(symbols["Address comments and merge PR 123"], "arrow.triangle.merge")
        XCTAssertEqual(symbols["Explain the code"], "sparkles")
    }

    @MainActor
    func testPresetsSurviveRelaunchAndDeletion() async throws {
        let url = directory.appendingPathComponent("presets.json")
        let store = TaskPresetStore(url: url)
        var preset = TaskTemplate(name: "Write docs", prompt: "Document {{input}}")
        preset.skillPaths = ["/example/skills/docs/SKILL.md"]
        try store.save(preset)
        let reloaded = TaskPresetStore(url: url)
        XCTAssertEqual(reloaded.preset(id: preset.id), preset)
        preset.prompt = "Explain {{input}} for a beginner"
        try reloaded.save(preset)
        XCTAssertEqual(TaskPresetStore(url: url).preset(id: preset.id).prompt, preset.prompt)
        try reloaded.remove(preset)
        XCTAssertFalse(TaskPresetStore(url: url).presets.contains { $0.id == preset.id })
        XCTAssertThrowsError(try reloaded.remove(.custom))
    }

    @MainActor
    func testPresetsAreOfferedByUseWithTheCustomTaskFirst() throws {
        let domain = "TaskConfigurationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = TaskPresetStore(url: directory.appendingPathComponent("presets.json"), defaults: defaults)
        XCTAssertEqual(store.presetsByUse.map(\.id), store.presets.map(\.id))

        let fixCI = store.preset(id: "fixCI"), review = store.preset(id: "reviewPR")
        store.recordUse(of: fixCI)
        store.recordUse(of: fixCI)
        store.recordUse(of: review)
        store.recordUse(of: .custom)
        XCTAssertEqual(store.presetsByUse.map(\.id), ["custom", "fixCI", "reviewPR", "chat", "implementTicket", "reviewComments"])
    }

    @MainActor
    func testInvalidPresetCannotReplaceSavedData() async throws {
        let url = directory.appendingPathComponent("presets.json")
        let store = TaskPresetStore(url: url)
        try store.save(TaskTemplate(name: "Valid"))
        let saved = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.save(TaskTemplate(name: " ", prompt: "")))
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    @MainActor
    func testCorruptPresetsArePreserved() async throws {
        let url = directory.appendingPathComponent("presets.json")
        try Data("broken json".utf8).write(to: url)
        let store = TaskPresetStore(url: url)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.save(TaskTemplate(name: "New")))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "broken json")
    }

    @MainActor
    func testSaveFailureDoesNotChangeInMemoryPresets() async throws {
        let blocked = directory.appendingPathComponent("file")
        try Data().write(to: blocked)
        let store = TaskPresetStore(url: blocked.appendingPathComponent("presets.json"))
        let before = store.presets
        XCTAssertThrowsError(try store.save(TaskTemplate(name: "New")))
        XCTAssertEqual(store.presets, before)
    }

    func testPromptIncludesInputNotesAndDistinctSkillFiles() throws {
        let url = try SkillFiles().create(name: "review", description: "Review code", instructions: "Read the diff.", root: directory)
        let preset = TaskTemplate(name: "Review", titlePattern: "Review {{input}}", prompt: "Inspect {{input}}")
        let prompt = try TaskPrompt(template: preset, input: "  PR-123  ", notes: "Focus on accessibility", skillPaths: [url.path, url.path])
        XCTAssertEqual(prompt.title, "Review PR-123")
        XCTAssertTrue(prompt.instructions.contains("Inspect PR-123"))
        XCTAssertTrue(prompt.instructions.contains("Focus on accessibility"))
        XCTAssertEqual(prompt.instructions.components(separatedBy: url.path).count, 2)
        XCTAssertFalse(prompt.instructions.contains("{{input}}"))
    }

    func testMissingSkillAndRequiredInputPreventLaunch() throws {
        XCTAssertThrowsError(try TaskPrompt(template: .custom, input: " ", notes: "", skillPaths: []))
        XCTAssertThrowsError(try TaskPrompt(template: .custom, input: "Work", notes: "", skillPaths: [directory.appendingPathComponent("missing/SKILL.md").path]))
        let optional = try XCTUnwrap(TaskTemplate.defaults.first { $0.id == "fixCI" })
        XCTAssertEqual(try TaskPrompt(template: optional, input: "", notes: "", skillPaths: []).title, "Fix CI")
    }

    func testPRPresetsPreserveSingleMultipleAndSourceInputs() throws {
        for (id, title) in [("reviewComments", "Resolve & merge:"), ("reviewPR", "Review PRs:")] {
            let preset = try XCTUnwrap(TaskTemplate.defaults.first { $0.id == id })
            for input in ["14901", "14901, 14903", "https://github.com/example/project/pull/1\nhttps://github.com/example/project/pull/2",
                          "https://example.com/discussions/review-batch"] {
                let task = try TaskPrompt(template: preset, input: input, notes: "Keep the scope explicit", skillPaths: [])
                XCTAssertTrue(task.instructions.contains(input))
                XCTAssertTrue(task.instructions.contains("Keep the scope explicit"))
                XCTAssertFalse(task.instructions.contains("{{input}}"))
                XCTAssertEqual(task.title, "\(title) \(input)")
            }
        }
    }

    func testImplementPresetAcceptsATicketOrAMission() throws {
        let preset = try XCTUnwrap(TaskTemplate.defaults.first { $0.id == "implementTicket" })
        for input in ["SK-123", "https://example.atlassian.net/browse/SK-123", "Add a dark mode toggle to the settings screen"] {
            let task = try TaskPrompt(template: preset, input: input, notes: "", skillPaths: [])
            XCTAssertEqual(task.title, "Implement \(input)")
            XCTAssertTrue(task.instructions.contains(input))
            XCTAssertFalse(task.instructions.contains("{{input}}"))
            XCTAssertFalse(task.instructions.contains("Implement ticket"))
        }
        XCTAssertThrowsError(try TaskPrompt(template: preset, input: " ", notes: "", skillPaths: []))
    }

    func testInputIsRetainedWhenPromptHasNoPlaceholder() throws {
        let preset = TaskTemplate(name: "Explain", prompt: "Explain this carefully.")
        let prompt = try TaskPrompt(template: preset, input: "An unusual API", notes: "", skillPaths: [])
        XCTAssertTrue(prompt.instructions.contains("An unusual API"))
    }
}
