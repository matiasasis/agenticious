import AppKit
import UniformTypeIdentifiers

/// An image pasted or dropped into the summon sheet. It stays in memory until the agent starts, then is written
/// into the session's folder, which archiving removes.
struct PastedImage: Identifiable {
    let id = UUID()
    let data: Data
    let fileExtension: String
    let preview: NSImage

    /// Formats the agents read as-is; anything else (HEIC, TIFF, …) is converted to PNG.
    private static let readableExtensions: Set = ["png", "jpg", "jpeg", "gif", "webp"]

    init?(file: URL) {
        guard let data = try? Data(contentsOf: file), let preview = NSImage(data: data) else { return nil }
        let fileExtension = file.pathExtension.lowercased()
        if Self.readableExtensions.contains(fileExtension) {
            self.init(data: data, fileExtension: fileExtension, preview: preview)
        } else {
            guard let png = Self.png(from: preview) else { return nil }
            self.init(data: png, fileExtension: "png", preview: preview)
        }
    }

    private init(data: Data, fileExtension: String, preview: NSImage) {
        self.data = data
        self.fileExtension = fileExtension
        self.preview = preview
    }

    /// Image files (a Finder copy) or, when there's no text to paste instead, raw image data (a screenshot).
    static func read(from pasteboard: NSPasteboard) -> [PastedImage] {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL] ?? []
        if !files.isEmpty { return files.compactMap(PastedImage.init(file:)) }

        guard pasteboard.string(forType: .string) == nil,
              let image = NSImage(pasteboard: pasteboard),
              let png = pasteboard.data(forType: .png) ?? png(from: image) else { return [] }
        return [PastedImage(data: png, fileExtension: "png", preview: image)]
    }

    static func save(_ images: [PastedImage], into directory: URL) throws -> [URL] {
        guard !images.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try images.enumerated().map { index, image in
            let url = directory.appendingPathComponent("image-\(index + 1).\(image.fileExtension)")
            try image.data.write(to: url)
            return url
        }
    }

    /// Codex also gets the files attached with `--image`; Claude reads them from these paths.
    static func instructions(for files: [URL]) -> String {
        guard !files.isEmpty else { return "" }
        let paths = files.map { "- " + $0.path }.joined(separator: "\n")
        return """


        Attached images:
        The human attached these images to the task. Look at each one before beginning.
        \(paths)
        """
    }

    private static func png(from image: NSImage) -> Data? {
        image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
    }
}
