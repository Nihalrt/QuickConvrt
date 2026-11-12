import Foundation
import PDFKit

private final class WordTextCheck: NSObject, XMLParserDelegate {
    var inText = false
    var hasText = false
    var hasTextBoxes = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        inText = elementName == "t" && namespaceURI == "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        if namespaceURI == "http://schemas.openxmlformats.org/wordprocessingml/2006/main" && ["txbxContent", "framePr"].contains(elementName) { hasTextBoxes = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText && !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasText = true }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" { inText = false }
    }
}

extension Converter {
    static func wordXMLContainsEditableText(_ xml: Data) -> Bool {
        let check = WordTextCheck()
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = check
        return parser.parse() && check.hasText
    }

    static func wordXMLContainsFlowingText(_ xml: Data) -> Bool {
        let check = WordTextCheck()
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = check
        return parser.parse() && check.hasText && !check.hasTextBoxes
    }

    static func validateEditableWord(_ url: URL, requireFlowing: Bool = false) throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/document.xml"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let xml = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, wordXMLContainsEditableText(xml) else {
            throw ConversionFailure("No editable Word text was produced. Conversion stopped instead of saving image-only pages.")
        }
        if requireFlowing && !wordXMLContainsFlowingText(xml) {
            throw ConversionFailure("The result contains positioned text boxes. No paragraph conversion was saved.")
        }
    }
    static func makeEditableDOCX(_ pdf: Data, pageCount: Int, mode: WordConversionMode = .flowing) throws -> Data {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // The app has access to the selected file. Give the helper a local
        // working copy so it doesn't need its own access to Documents.
        let source = temporary.appendingPathComponent("source.pdf")
        try pdf.write(to: source)
        let result = temporary.appendingPathComponent("editable.docx")
        try runPDFEngine(source: source, result: result, mode: mode.engineValue,
                         timeoutMessage: "This PDF took too long to reconstruct. Try a smaller page range.",
                         failureMessage: "This PDF couldn’t be reconstructed. No image-only or plain-text fallback was saved.")
        try validateEditableWord(result, requireFlowing: mode == .flowing)
        let data = try Data(contentsOf: result)
        // Check the generated Word package using the same local renderer used
        // for Word → PDF. A failed export never becomes a successful conversion.
        let rendered = try OfficeEngine.convert(result, to: .pdf)
        guard let check = PDFDocument(data: rendered),
              check.pageCount > 0 else { throw ConversionFailure("The converted Word document couldn’t be verified.") }
        if mode == .layout && pageCount != check.pageCount {
            throw ConversionFailure("The Word layout changed the number of pages. No output was saved. Try Editable paragraphs, or split the PDF into smaller sections.")
        }
        return data
    }

    static func runPDFEngine(source: URL, result: URL, mode: String, timeout: Int = 180, timeoutMessage: String, failureMessage: String) throws {
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("PDFEngine/pdf-editable"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ConversionFailure("The local conversion engine is missing. Reinstall the complete Docenlume app.")
        }
        let log = result.deletingLastPathComponent().appendingPathComponent("conversion.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errorFile = try FileHandle(forWritingTo: log)
        defer { try? errorFile.close() }
        let process = Process()
        process.executableURL = helper
        process.arguments = [source.path, result.path, "--mode", mode]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorFile
        var environment = ProcessInfo.processInfo.environment
        for key in ["PYTHONPATH", "PYTHONHOME"] { environment.removeValue(forKey: key) }
        environment["PYTHONNOUSERSITE"] = "1"
        process.environment = environment
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            throw ConversionFailure(timeoutMessage)
        }
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").last.map(String.init)
            throw ConversionFailure(message ?? failureMessage)
        }
    }
}
