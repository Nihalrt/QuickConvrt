import Foundation

enum CompressionMode: String, CaseIterable {
    case reduceSize = "Reduce file size"
    case zip = "Create ZIP"

    static func preferred(for files: [URL]) -> Self {
        !files.isEmpty && files.allSatisfy(Converter.canReduceSize) ? .reduceSize : .zip
    }
}

extension Converter {
    static func canReduceSize(_ source: URL) -> Bool {
        ["pdf", "jpg", "jpeg", "png"].contains(source.pathExtension.lowercased())
    }

    static func reduceSize(_ source: URL, in outputDirectory: URL) throws -> URL {
        let sourceScope = source.startAccessingSecurityScopedResource()
        defer { if sourceScope { source.stopAccessingSecurityScopedResource() } }
        let destinationScope = outputDirectory.startAccessingSecurityScopedResource()
        defer { if destinationScope { outputDirectory.stopAccessingSecurityScopedResource() } }
        try validateOutputDirectory(outputDirectory)

        guard canReduceSize(source) else {
            throw ConversionFailure("Reduce file size supports PDF, JPEG, and PNG. Use Create ZIP for other files.")
        }
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, let originalSize = attributes.fileSize else {
            throw ConversionFailure("Choose a file to compress.")
        }

        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Docenlume-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let input = work.appendingPathComponent("source").appendingPathExtension(source.pathExtension)
        let result = work.appendingPathComponent("compressed").appendingPathExtension(source.pathExtension)
        try manager.copyItem(at: source.resolvingSymlinksInPath(), to: input)
        try runPDFEngine(source: input, result: result, mode: "reduce-size",
                         timeout: 900, timeoutMessage: "Compression took too long. Try Create ZIP.",
                         failureMessage: "Couldn’t compress this file.")

        let size = try result.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size < originalSize else {
            throw ConversionFailure("This file is already compact. No smaller copy was saved.")
        }
        let staging = outputDirectory.appendingPathComponent(".docenlume-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(result.lastPathComponent)
        try manager.copyItem(at: result, to: staged)
        return try moveIntoOutputFolder(staged, named: source.lastPathComponent, in: outputDirectory)
    }
}
