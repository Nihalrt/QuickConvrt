import Foundation

struct ArchiveInputError: LocalizedError {
    let file: URL
    let cause: Error
    var errorDescription: String? { "\(file.lastPathComponent): \(cause.localizedDescription)" }
}

extension Converter {
    static func compress(_ sources: [URL], in outputDirectory: URL) throws -> URL {
        guard let first = sources.first else { throw ConversionFailure("Choose files to compress.") }
        let scopedDestination = outputDirectory.startAccessingSecurityScopedResource()
        defer { if scopedDestination { outputDirectory.stopAccessingSecurityScopedResource() } }
        try validateOutputDirectory(outputDirectory)

        let manager = FileManager.default
        let inputs = manager.temporaryDirectory.appendingPathComponent("Docenlume-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: inputs, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: inputs) }

        let entries = try sources.map { source in
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw ConversionFailure("Choose files to compress. Folders aren’t supported.")
                }
                let staged = try saveOutput(named: source.lastPathComponent, in: inputs) { destination in
                    try manager.copyItem(at: source, to: destination)
                }
                let parent = staged.deletingLastPathComponent()
                let relative = parent.path == inputs.path ? staged.lastPathComponent : "\(parent.lastPathComponent)/\(staged.lastPathComponent)"
                return "./\(relative)"
            } catch {
                throw ArchiveInputError(file: source, cause: error)
            }
        }

        let scratch = outputDirectory.appendingPathComponent(".docenlume-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: scratch) }
        let archive = scratch.appendingPathComponent("output.zip")
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        writer.currentDirectoryURL = inputs
        // Prefix the input paths so names such as '-' and '@notes' are literal.
        // Strip that prefix from the ZIP entries.
        writer.arguments = ["--disable-copyfile", "-n", "--format", "zip", "--options", "zip:hdrcharset=UTF-8",
                            "-s", #"|^\./||"#, "-cf", archive.path, "--"] + entries
        writer.environment = ["LC_ALL": "en_US.UTF-8"]
        writer.standardOutput = FileHandle.nullDevice
        writer.standardError = FileHandle.nullDevice
        try writer.run()
        writer.waitUntilExit()
        guard writer.terminationStatus == 0 else {
            throw ConversionFailure("Couldn’t create the ZIP archive. Check that the save folder has enough space.")
        }

        let name = sources.count == 1 ? outputName(for: first, extension: "zip") : "Archive.zip"
        return try moveIntoOutputFolder(archive, named: name, in: outputDirectory)
    }
}
