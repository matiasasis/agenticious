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

    func testInputIsRetainedWhenPromptHasNoPlaceholder() throws {
        let preset = TaskTemplate(name: "Explain", prompt: "Explain this carefully.")
        let prompt = try TaskPrompt(template: preset, input: "An unusual API", notes: "", skillPaths: [])
        XCTAssertTrue(prompt.instructions.contains("An unusual API"))
    }
}
