import AppKit
import XCTest
@testable import Agenticious

final class PastedImageTests: XCTestCase {
    private var directory: URL!
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try FileManager.default.removeItem(at: directory)
    }

    func testReadsScreenshotDataAsPNG() throws {
        pasteboard.clearContents()
        pasteboard.setData(try png(), forType: .png)

        let images = PastedImage.read(from: pasteboard)

        XCTAssertEqual(images.map(\.fileExtension), ["png"])
    }

    func testTextOnTheClipboardPastesAsText() throws {
        pasteboard.clearContents()
        pasteboard.setData(try png(), forType: .png)
        pasteboard.setString("a sentence", forType: .string)

        XCTAssertTrue(PastedImage.read(from: pasteboard).isEmpty)
    }

    func testReadsCopiedImageFilesButNotOtherFiles() throws {
        let image = directory.appendingPathComponent("shot.JPG")
        let text = directory.appendingPathComponent("notes.txt")
        try png().write(to: image)
        try Data("notes".utf8).write(to: text)
        pasteboard.clearContents()
        pasteboard.writeObjects([image as NSURL, text as NSURL])

        XCTAssertEqual(PastedImage.read(from: pasteboard).map(\.fileExtension), ["jpg"])
    }

    func testConvertsFormatsAgentsCannotReadToPNG() throws {
        let tiff = directory.appendingPathComponent("scan.tiff")
        try XCTUnwrap(NSImage(data: try png())?.tiffRepresentation).write(to: tiff)

        XCTAssertEqual(PastedImage(file: tiff)?.fileExtension, "png")
    }

    func testSavesNumberedFilesAndPointsThePromptAtThem() throws {
        pasteboard.clearContents()
        pasteboard.setData(try png(), forType: .png)
        let images = PastedImage.read(from: pasteboard) + PastedImage.read(from: pasteboard)

        let files = try PastedImage.save(images, into: directory.appendingPathComponent("images"))

        XCTAssertEqual(files.map(\.lastPathComponent), ["image-1.png", "image-2.png"])
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(PastedImage.instructions(for: files).contains("- " + files[1].path))
        XCTAssertEqual(PastedImage.instructions(for: []), "")
    }

    @MainActor
    func testCodexGetsEachImageAttached() throws {
        let files = [directory.appendingPathComponent("image-1.png"), directory.appendingPathComponent("image-2.png")]
        let session = AgentSession(task: "Match the mockup", agent: .codex, project: .none, directory: directory)

        let spec = try AgentLauncher(port: 1).spec(for: session, images: files)

        XCTAssertTrue(spec.arguments[1].contains(#"--image "$AD_IMAGE_0" --image "$AD_IMAGE_1""#))
        XCTAssertTrue(spec.environment.contains("AD_IMAGE_1=" + files[1].path))
    }

    private func png() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
