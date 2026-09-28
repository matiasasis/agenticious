import XCTest
@testable import Agenticious

final class SkillCatalogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testDiscoveryFollowsSymlinksWithoutDuplicatesOrCycles() throws {
        let skill = try SkillFiles().create(name: "example", description: "Useful: even with punctuation", instructions: "Do the task.", root: directory)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias"), withDestinationURL: skill.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("cycle"), withDestinationURL: directory)
        let result = SkillScanner().scan(sources: [SkillSource(url: directory, label: "Test")])
        XCTAssertEqual(result.skills.count, 1)
        XCTAssertEqual(result.skills.first?.summary, "Useful: even with punctuation")
        XCTAssertEqual(result.skills.first?.id, skill.path)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testMissingRootsAreNormalButInvalidFilesAreReported() throws {
        let bad = directory.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data([0xff, 0xfe, 0xff]).write(to: bad.appendingPathComponent("SKILL.md"))
        let result = SkillScanner().scan(sources: [SkillSource(url: directory, label: "Test"), SkillSource(url: directory.appendingPathComponent("missing"), label: "Missing")])
        XCTAssertTrue(result.skills.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
    }

    func testProjectDiscoveryStopsAtRepositoryRoot() throws {
        let repo = directory.appendingPathComponent("repo")
        let child = repo.appendingPathComponent("packages/app")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let paths = SkillScanner(home: directory, codexHome: nil).sources(projectPath: child.path, extraPaths: [])
            .filter { $0.label.hasPrefix("Project") }.map(\.url.path)
        XCTAssertTrue(paths.contains(child.appendingPathComponent(".agents/skills").path))
        XCTAssertTrue(paths.contains(repo.appendingPathComponent(".agents/skills").path))
        XCTAssertEqual(paths.count, 9)
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix(repo.path + "/") })
    }

    func testMetadataSupportsQuotedAndMultilineDescriptions() {
        let folded = SkillDocument(text: "---\nname: 'my-skill'\ndescription: >-\n  First line\n  second line\nmetadata:\n  short: ignore\n---\nBody")
        XCTAssertEqual(folded.name, "my-skill")
        XCTAssertEqual(folded.summary, "First line second line")
        let literal = SkillDocument(text: "---\nname: test\ndescription: |\n  One\n  Two\n---\nBody")
        XCTAssertEqual(literal.summary, "One\nTwo")
    }

    func testCreationRejectsTraversalAndExistingSkills() throws {
        let files = SkillFiles()
        XCTAssertThrowsError(try files.create(name: "../escape", description: "Test", instructions: "Test", root: directory))
        let url = try files.create(name: "example", description: "Test", instructions: "Original", root: directory)
        XCTAssertThrowsError(try files.create(name: "example", description: "Test", instructions: "Replacement", root: directory))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Original"))
    }

    func testOversizedSkillsAreRejectedBeforeWriting() throws {
        let files = SkillFiles()
        let oversized = String(repeating: "x", count: 1_048_577)
        XCTAssertThrowsError(try files.create(name: "large", description: "Test", instructions: oversized, root: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("large").path))
        let url = try files.create(name: "small", description: "Test", instructions: "Original", root: directory)
        let original = try String(contentsOf: url, encoding: .utf8)
        XCTAssertThrowsError(try files.save(original + oversized, to: url, original: original))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testEditingPreservesMetadataAndDetectsExternalChanges() throws {
        let url = try SkillFiles().create(name: "example", description: "Test", instructions: "Original", root: directory)
        let original = try String(contentsOf: url, encoding: .utf8)
        let updated = original.replacingOccurrences(of: "Original", with: "Updated")
        try SkillFiles().save(updated, to: url, original: original)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), updated)
        XCTAssertThrowsError(try SkillFiles().save(original, to: url, original: original))
        XCTAssertThrowsError(try SkillFiles().save("No frontmatter", to: url, original: updated))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), updated)
    }
}
