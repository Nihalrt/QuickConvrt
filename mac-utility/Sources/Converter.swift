import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import CoreText

enum OutputFormat: String, CaseIterable {
    case pdf = "PDF", docx = "DOCX", jpg = "JPEG", png = "PNG", tiff = "TIFF", txt = "TXT", zip = "ZIP", psd = "PSD"
    var ext: String { self == .jpg ? "jpg" : rawValue.lowercased() }
    var isImage: Bool { [.jpg, .png, .tiff].contains(self) }
    var symbol: String { self == .zip ? "doc.zipper" : isImage ? "photo" : self == .docx ? "doc.richtext" : "doc.text" }
    var wheelTitle: String { self == .zip ? "Compress" : rawValue }
}

struct ConversionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum ConversionAccessError: LocalizedError {
    case source, destination

    var errorDescription: String? {
        switch self {
        case .source: return "macOS blocked access to this file. Choose it again in the file picker."
        case .destination: return "macOS blocked writes to this folder. Choose the save folder again."
        }
    }

    static func classify(_ error: Error, in folder: URL) -> Self? {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return nil }
        if nsError.code == CocoaError.fileReadNoPermission.rawValue { return .source }
        if nsError.code == CocoaError.fileWriteNoPermission.rawValue,
           let path = nsError.userInfo[NSFilePathErrorKey] as? String {
            let destination = folder.standardizedFileURL.path
            let attempted = URL(fileURLWithPath: path).standardizedFileURL.path
            if attempted == destination || attempted.hasPrefix(destination + "/") { return .destination }
        }
        return nil
    }
}

enum WordConversionMode: String, CaseIterable {
    case flowing = "Editable paragraphs", layout = "Page layout (text boxes)"
    var engineValue: String { self == .layout ? "layout" : "flowing" }
}

enum Converter {
    static let textExtensions = ["txt", "md", "csv", "json", "log", "xml", "yaml", "yml"]
    static let richExtensions = ["docx", "doc", "rtf", "odt"]
    static let imageExtensions = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "webp", "gif", "bmp", "psd"]

    static func supports(_ url: URL) -> Bool {
        let type = url.pathExtension.lowercased()
        return type == "pdf" || (textExtensions + richExtensions + imageExtensions).contains(type)
    }

    static func isAlreadyFormat(_ url: URL, _ format: OutputFormat) -> Bool {
        let source = url.pathExtension.lowercased()
        return format != .zip && (source == format.ext || (source == "jpeg" && format == .jpg) || (source == "tif" && format == .tiff))
    }

    static func filesNeedingConversion(_ urls: [URL], to format: OutputFormat) -> [URL] {
        urls.filter { !isAlreadyFormat($0, format) }
    }

    static func validate(_ url: URL, as format: OutputFormat) throws {
        let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attrs.isRegularFile == true else { throw ConversionFailure("Choose files, rather than folders.") }
        guard (attrs.fileSize ?? 0) <= 100 * 1024 * 1024 else { throw ConversionFailure("Files must be smaller than 100 MB.") }
        guard supports(url) else { throw ConversionFailure("This file type isn’t supported yet.") }
        guard format != .psd else { throw ConversionFailure("PSD export needs a Photoshop engine. Try PNG or TIFF.") }
        let source = url.pathExtension.lowercased()
        guard !isAlreadyFormat(url, format) else {
            throw ConversionFailure("This file is already \(format.rawValue). Pick another format.")
        }
        if imageExtensions.contains(source) && [.txt, .docx].contains(format) {
            throw ConversionFailure("Images convert to PDF, JPEG, PNG, or TIFF. Text recognition isn’t included yet.")
        }
    }

    static func validateOutputDirectory(_ folder: URL) throws {
        guard folder.isFileURL,
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw ConversionFailure("The save folder is unavailable. Choose another folder using Save to.")
        }
    }

    static func outputName(for source: URL, extension ext: String) -> String {
        if source.pathExtension.lowercased() == ext.lowercased() { return source.lastPathComponent }
        return source.deletingPathExtension().appendingPathExtension(ext).lastPathComponent
    }

    static func saveOutput(named name: String, in folder: URL, write: (URL) throws -> Void) throws -> URL {
        let manager = FileManager.default
        let preferred = folder.appendingPathComponent(name)
        if !manager.fileExists(atPath: preferred.path) {
            do {
                try write(preferred)
                return preferred
            } catch CocoaError.fileWriteFileExists {
                // Another operation may have claimed the name.
            }
        }
        for number in 1...10_000 {
            let nameOfFolder = number == 1 ? "Docenlume" : "Docenlume \(number)"
            let subfolder = folder.appendingPathComponent(nameOfFolder, isDirectory: true)
            do {
                try manager.createDirectory(at: subfolder, withIntermediateDirectories: false)
            } catch CocoaError.fileWriteFileExists {
                continue
            }
            let destination = subfolder.appendingPathComponent(name)
            do {
                try write(destination)
                return destination
            } catch {
                // Only remove our folder if it is empty.
                _ = rmdir(subfolder.path)
                throw error
            }
        }
        throw ConversionFailure("Choose another save folder. Too many Docenlume folders already exist here.")
    }

    static func moveIntoOutputFolder(_ file: URL, named name: String, in folder: URL) throws -> URL {
        try saveOutput(named: name, in: folder) { destination in
            try FileManager.default.moveItem(at: file, to: destination)
        }
    }

    private static func save(_ data: Data, from source: URL, as format: OutputFormat, in folder: URL) throws -> [URL] {
        let target = try saveOutput(named: outputName(for: source, extension: format.ext), in: folder) { destination in
            try data.write(to: destination, options: .withoutOverwriting)
        }
        return [target]
    }

    static func convert(_ source: URL, to format: OutputFormat, in outputDirectory: URL, wordMode: WordConversionMode = .flowing) throws -> [URL] {
        if format == .zip { return [try compress([source], in: outputDirectory)] }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let scopedDestination = outputDirectory.startAccessingSecurityScopedResource()
        defer { if scopedDestination { outputDirectory.stopAccessingSecurityScopedResource() } }
        try validate(source, as: format)
        try validateOutputDirectory(outputDirectory)
        let type = source.pathExtension.lowercased()
        if imageExtensions.contains(type) {
            let image = try readImage(source)
            let data = format == .pdf ? imagePDF(image) : try imageData(image, to: format)
            return try save(data, from: source, as: format, in: outputDirectory)
        }
        if richExtensions.contains(type), format != .txt {
            let data = try OfficeEngine.convert(source, to: format == .docx ? .docx : .pdf)
            if format.isImage {
                guard let pdf = PDFDocument(data: data) else { throw ConversionFailure("Couldn’t render the document.") }
                return try renderPDF(pdf, source: source, format: format, in: outputDirectory)
            }
            return try save(data, from: source, as: format, in: outputDirectory)
        }
        let text: String
        if type == "pdf" {
            // Read explicitly so file-access errors aren't lost in PDFKit's nil result.
            let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
            guard let pdf = PDFDocument(data: bytes) else { throw ConversionFailure("This file couldn’t be read as a PDF.") }
            guard !pdf.isLocked else { throw ConversionFailure("This PDF requires a password. Save an unlocked copy and try again.") }
            guard pdf.pageCount <= 100 else { throw ConversionFailure("Split this PDF into files of 100 pages or fewer.") }
            if format.isImage { return try renderPDF(pdf, source: source, format: format, in: outputDirectory) }
            if format == .docx {
                let data = try makeEditableDOCX(bytes, pageCount: pdf.pageCount, mode: wordMode)
                return try save(data, from: source, as: format, in: outputDirectory)
            }
            text = pdf.string ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversionFailure("No selectable text found. Scanned PDFs need OCR.")
            }
        } else {
            text = try readText(source)
        }
        if format == .txt { return try save(Data(text.utf8), from: source, as: format, in: outputDirectory) }
        if format == .docx { return try save(makeDOCX(text), from: source, as: format, in: outputDirectory) }
        let data = try textPDF(text)
        if format == .pdf { return try save(data, from: source, as: format, in: outputDirectory) }
        guard let pdf = PDFDocument(data: data) else { throw ConversionFailure("Couldn’t render the document.") }
        return try renderPDF(pdf, source: source, format: format, in: outputDirectory)
    }

    static func readText(_ source: URL) throws -> String {
        if textExtensions.contains(source.pathExtension.lowercased()) {
            let data = try Data(contentsOf: source)
            guard let value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                throw ConversionFailure("Save this text file with UTF-8 or UTF-16 encoding, then try again.")
            }
            return value
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("text.txt")
        try textutil(["-convert", "txt", "-encoding", "UTF-8", "-output", output.path, source.path])
        let text = try String(contentsOf: output, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionFailure("This document has no editable text. For image-based Word files, use the original PDF for further conversions.")
        }
        return text
    }

    static func textutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = arguments
        // No shell interpolation, network imports, or external conversion services.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ConversionFailure("macOS couldn’t read this document. Try exporting it as DOCX, RTF, or TXT first.") }
    }

    static func makeDOCX(_ text: String) throws -> Data {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = temporary.appendingPathComponent("input.txt"), output = temporary.appendingPathComponent("output.docx")
        try text.write(to: input, atomically: true, encoding: .utf8)
        try textutil(["-convert", "docx", "-inputencoding", "UTF-8", "-output", output.path, input.path])
        return try Data(contentsOf: output)
    }

    static func textPDF(_ text: String) throws -> Data {
        let bytes = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: bytes), let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ConversionFailure("Couldn’t create a PDF.")
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let value = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
        let framesetter = CTFramesetterCreateWithAttributedString(value)
        let path = CGPath(rect: CGRect(x: 48, y: 48, width: 499, height: 746), transform: nil)
        var offset = 0, count = 0
        repeat {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let range = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            guard range.length > 0 else { throw ConversionFailure("The text couldn’t be laid out.") }
            offset += range.length
            count += 1
            guard count <= 1000 else { throw ConversionFailure("This text document is too long to convert.") }
        } while offset < value.length
        context.closePDF()
        return bytes as Data
    }

    static func readImage(_ source: URL) throws -> CGImage {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 100_000_000 else {
            throw ConversionFailure("macOS couldn’t decode this image, or it exceeds 100 megapixels. PSD needs a compatible flattened preview.")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: min(8192, max(width, height))]
        guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else { throw ConversionFailure("Couldn’t decode this image.") }
        return image
    }

    static func imageData(_ image: CGImage, to format: OutputFormat, dpi: Double? = nil) throws -> Data {
        let type: CFString = (format == .jpg ? UTType.jpeg.identifier : format == .png ? UTType.png.identifier : UTType.tiff.identifier) as CFString
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, type, 1, nil) else { throw ConversionFailure("This image format isn’t available on this Mac.") }
        var rendered = image
        if format == .jpg {
            if let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect); context.draw(image, in: rect)
                if let flattened = context.makeImage() { rendered = flattened }
            }
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.94]
        if let dpi { properties[kCGImagePropertyDPIWidth] = dpi; properties[kCGImagePropertyDPIHeight] = dpi }
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionFailure("Couldn’t write the image.") }
        return bytes as Data
    }

    static func imagePDF(_ image: CGImage) -> Data {
        let document = PDFDocument()
        if let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) { document.insert(page, at: 0) }
        return document.dataRepresentation() ?? Data()
    }

    static func renderPDF(_ document: PDFDocument, source: URL, format: OutputFormat, in outputDirectory: URL) throws -> [URL] {
        guard document.pageCount > 0, document.pageCount <= 100 else { throw ConversionFailure("PDFs must have between 1 and 100 pages.") }
        if document.pageCount == 1 {
            return try save(renderPage(0, of: document, as: format), from: source, as: format, in: outputDirectory)
        }
        let staging = outputDirectory.appendingPathComponent(".docenlume-\(UUID())", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let name = outputName(for: source, extension: format.ext)
        for index in 0..<document.pageCount {
            try autoreleasepool {
                let pageFolder = staging.appendingPathComponent(String(format: "Page %03d", index + 1), isDirectory: true)
                try manager.createDirectory(at: pageFolder, withIntermediateDirectories: false)
                let destination = pageFolder.appendingPathComponent(name)
                try renderPage(index, of: document, as: format).write(to: destination, options: .withoutOverwriting)
            }
        }
        let directory = try moveIntoOutputFolder(staging, named: source.deletingPathExtension().lastPathComponent, in: outputDirectory)
        return [directory]
    }

    private static func renderPage(_ index: Int, of document: PDFDocument, as format: OutputFormat) throws -> Data {
        guard let page = document.page(at: index) else { throw ConversionFailure("Couldn’t read PDF page \(index + 1).") }
        let rect = page.bounds(for: .cropBox)
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { throw ConversionFailure("This PDF has an invalid page size.") }
        let scale = min(300 / 72, 8192 / max(rect.width, rect.height), sqrt(32_000_000 / (rect.width * rect.height)))
        let size = page.rotation % 180 == 0 ? rect.size : NSSize(width: rect.height, height: rect.width)
        let thumb = page.thumbnail(of: NSSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
        var proposed = CGRect(origin: .zero, size: thumb.size)
        guard let image = thumb.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { throw ConversionFailure("Couldn’t render PDF page \(index + 1).") }
        return try imageData(image, to: format, dpi: Double(image.width) / Double(size.width) * 72)
    }
}
