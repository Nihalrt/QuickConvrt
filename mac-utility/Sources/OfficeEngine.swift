import Foundation
import PDFKit

/// Render the original office package. Never extract its text as a PDF fallback.
enum OfficeEngine {
    static func convert(_ source: URL, to format: OutputFormat) throws -> Data {
        guard [.pdf, .docx].contains(format) else { throw ConversionFailure("Unsupported office export.") }
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("OfficeEngine/LibreOfficeDev.app/Contents/MacOS/soffice"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ConversionFailure("The document renderer is missing. Reinstall the complete Docenlume app; formatting will not be replaced with plain text.")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Docenlume-office-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let profile = work.appendingPathComponent("profile", isDirectory: true)
        let profileUser = profile.appendingPathComponent("user", isDirectory: true)
        let output = work.appendingPathComponent("output", isDirectory: true)
        try fm.createDirectory(at: profileUser, withIntermediateDirectories: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        // Disable macros and automatic external-link updates in the isolated profile.
        let settings = """
        <?xml version="1.0" encoding="UTF-8"?>
        <oor:items xmlns:oor="http://openoffice.org/2001/registry">
        <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
        <item oor:path="/org.openoffice.Office.Writer/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>2</value></prop></item>
        </oor:items>
        """
        try settings.write(to: profileUser.appendingPathComponent("registrymodifications.xcu"), atomically: true, encoding: .utf8)
        let input = work.appendingPathComponent("document").appendingPathExtension(source.pathExtension.lowercased())
        try fm.copyItem(at: source, to: input)
        let pdfOptions = #"pdf:writer_pdf_Export:{"UseLosslessCompression":{"type":"boolean","value":"true"},"ReduceImageResolution":{"type":"boolean","value":"false"},"ExportBookmarks":{"type":"boolean","value":"true"},"UseTaggedPDF":{"type":"boolean","value":"true"},"EmbedStandardFonts":{"type":"boolean","value":"true"}}"#
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--invisible", "--nologo", "--nodefault", "--nofirststartwizard", "--norestore", "--convert-to", format == .pdf ? pdfOptions : "docx:Office Open XML Text", "--outdir", output.path, input.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["SAL_USE_VCLPLUGIN"] = "svp"
        process.environment = environment
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 120) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            throw ConversionFailure("The document renderer timed out. Try opening and resaving the original document in Word.")
        }
        let result = output.appendingPathComponent("document").appendingPathExtension(format.ext)
        guard process.terminationStatus == 0, fm.fileExists(atPath: result.path) else {
            throw ConversionFailure("The document renderer couldn’t export this file. The original may be encrypted, damaged, or use unsupported features. No plain-text fallback was saved.")
        }
        let data = try Data(contentsOf: result)
        if format == .pdf {
            guard data.starts(with: Data("%PDF-".utf8)), let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
                throw ConversionFailure("The document renderer did not produce a valid PDF.")
            }
        } else if !data.starts(with: [0x50, 0x4b]) {
            throw ConversionFailure("The document renderer did not produce a valid Word document.")
        }
        return data
    }
}
