import AppKit
import PDFKit
import ImageIO

func runSelfTest() throws {
    func expect(_ condition: Bool, _ description: String) throws {
        guard condition else { throw ConversionFailure(description) }
        print("PASS: \(description)")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Docenlume-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputDirectory = directory.appendingPathComponent("Chosen folder")
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let input = directory.appendingPathComponent("example.txt")
    try expect(OutputFormat.allCases.filter { $0 != .zip }.allSatisfy { format in
        Converter.isAlreadyFormat(directory.appendingPathComponent("example.\(format.ext.uppercased())"), format)
    }, "Same-format detection handles every format and uppercase extensions")
    try expect(Converter.isAlreadyFormat(directory.appendingPathComponent("photo.JPEG"), .jpg) && Converter.isAlreadyFormat(directory.appendingPathComponent("scan.TIF"), .tiff), "JPEG/JPG and TIF/TIFF aliases count as the same format")
    try expect(!Converter.isAlreadyFormat(directory.appendingPathComponent("old.doc"), .docx), "Legacy DOC still converts to DOCX")
    let existingPDF = directory.appendingPathComponent("already.pdf")
    try expect(Converter.filesNeedingConversion([existingPDF], to: .pdf).isEmpty && Converter.filesNeedingConversion([existingPDF, input], to: .pdf) == [input], "Already-converted files are skipped in single and mixed batches")
    let text = "Every file. A new possibility.\nCafé — Ελληνικά — Привет — 日本語\n" + String(repeating: "One little switch. So many possibilities.\n", count: 100)
    try text.write(to: input, atomically: true, encoding: .utf8)
    let pdfURL = try Converter.convert(input, to: .pdf, in: outputDirectory)[0]
    try expect(pdfURL.lastPathComponent == "example.pdf", "Single-file output uses the original name with its new extension")
    let pdf = PDFDocument(url: pdfURL)!
    try expect(pdf.pageCount > 1, "Text → paginated PDF")
    try expect(pdf.string?.contains("Every file") == true, "PDF contains selectable source text")
    let deniedPDF = directory.appendingPathComponent("blocked.pdf")
    try FileManager.default.copyItem(at: pdfURL, to: deniedPDF)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: deniedPDF.path)
    do {
        defer { try? FileManager.default.removeItem(at: deniedPDF) }
        _ = try Converter.convert(deniedPDF, to: .png, in: outputDirectory)
        throw ConversionFailure("A PDF that cannot be read must not be converted")
    } catch {
        try expect(ConversionAccessError.classify(error, in: outputDirectory) == .source,
                   "PDF read denial is detected separately from a password lock")
    }
    let docxURL = try Converter.convert(input, to: .docx, in: outputDirectory)[0]
    try expect(try Data(contentsOf: docxURL).prefix(2) == Data([0x50, 0x4b]), "Text → valid DOCX container")
    let roundTrip = try Converter.convert(docxURL, to: .txt, in: outputDirectory)[0]
    try expect(try String(contentsOf: roundTrip, encoding: .utf8).contains("Ελληνικά"), "DOCX → TXT retains Unicode text")
    let wordPDF = try Converter.convert(docxURL, to: .pdf, in: outputDirectory)[0]
    try expect(PDFDocument(url: wordPDF)?.pageCount == pdf.pageCount, "DOCX → PDF")
    let images = try Converter.convert(pdfURL, to: .png, in: outputDirectory)[0]
    let pageFolders = try FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    let pages = pageFolders.map { $0.appendingPathComponent("example.png") }
    try expect(pages.count == pdf.pageCount, "Every PDF page becomes a PNG")
    let expectedPageFolders = (1...pdf.pageCount).map { String(format: "Page %03d", $0) }
    try expect(images.lastPathComponent == "example" && pageFolders.map(\.lastPathComponent) == expectedPageFolders &&
               pages.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
               "Multi-page exports preserve filenames and number the page folders")
    let cropped = PDFDocument(data: try Converter.textPDF("Cropped and rotated image export"))!
    let cropPage = cropped.page(at: 0)!
    cropPage.setBounds(CGRect(x: 20, y: 20, width: 200, height: 100), for: .cropBox)
    cropPage.rotation = 90
    let cropSource = directory.appendingPathComponent("Crop test.v1.pdf")
    try cropped.dataRepresentation()!.write(to: cropSource)
    let cropOutput = try Converter.convert(cropSource, to: .png, in: outputDirectory)[0]
    try expect(cropOutput.lastPathComponent == "Crop test.v1.png", "Single-page image exports keep spaces and dots in the original name")
    let cropImageSource = CGImageSourceCreateWithURL(cropOutput as CFURL, nil)!
    let cropProperties = CGImageSourceCopyPropertiesAtIndex(cropImageSource, 0, nil) as! [CFString: Any]
    let cropWidth = cropProperties[kCGImagePropertyPixelWidth] as! Int
    let cropHeight = cropProperties[kCGImagePropertyPixelHeight] as! Int
    try expect(abs(cropWidth - 417) <= 2 && abs(cropHeight - 833) <= 2, "PDF image export respects crop, rotation, and 300 dpi dimensions")
    try expect(abs((cropProperties[kCGImagePropertyDPIWidth] as? Double ?? 0) - 300) < 2, "PDF page images keep their physical print size through DPI metadata")
    try FileManager.default.removeItem(at: cropSource)
    let image = pages[0]
    let jpeg = try Converter.convert(image, to: .jpg, in: outputDirectory)[0]
    try expect(CGImageSourceCreateWithURL(jpeg as CFURL, nil) != nil, "PNG → decodable JPEG")
    let tiff = try Converter.convert(jpeg, to: .tiff, in: outputDirectory)[0]
    try expect(CGImageSourceCreateWithURL(tiff as CFURL, nil) != nil, "JPEG → decodable TIFF")
    let imagePDF = try Converter.convert(image, to: .pdf, in: outputDirectory)[0]
    try expect(PDFDocument(url: imagePDF)?.pageCount == 1, "Image → PDF")
    let pdfText = try Converter.convert(pdfURL, to: .txt, in: outputDirectory)[0]
    try expect(try String(contentsOf: pdfText, encoding: .utf8).contains("Every file"), "PDF → TXT")
    let pdfDocx = try Converter.convert(pdfURL, to: .docx, in: outputDirectory, wordMode: .layout)[0]
    try Converter.validateEditableWord(pdfDocx)
    let verifiedPDF = PDFDocument(data: try OfficeEngine.convert(pdfDocx, to: .pdf))!
    try expect(verifiedPDF.pageCount == pdf.pageCount, "PDF → editable Word preserves page count and passes local rendering")
    try expect(verifiedPDF.string?.contains("Every file") == true, "PDF → Word keeps real selectable text after rendering")
    let shortPDF = directory.appendingPathComponent("short.pdf")
    try Converter.textPDF("A simple editable paragraph for the local engine.").write(to: shortPDF)
    let flowing = try Converter.convert(shortPDF, to: .docx, in: outputDirectory, wordMode: .flowing)[0]
    try Converter.validateEditableWord(flowing, requireFlowing: true)
    print("PASS: Editable paragraphs mode works without an account or API")
    try FileManager.default.removeItem(at: shortPDF)
    let imageOnlyXML = Data("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:drawing/></w:r></w:p></w:body></w:document>".utf8)
    try expect(!Converter.wordXMLContainsEditableText(imageOnlyXML), "Image-only output is rejected before saving")
    let boxedXML = Data("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:txbxContent><w:p><w:r><w:t>Boxed text</w:t></w:r></w:p></w:txbxContent></w:p></w:body></w:document>".utf8)
    try expect(Converter.wordXMLContainsEditableText(boxedXML) && !Converter.wordXMLContainsFlowingText(boxedXML), "Paragraph mode rejects positioned text boxes")
    try Converter.validateEditableWord(docxURL)
    print("PASS: Editable text passes the output gate")
    let again = try Converter.convert(input, to: .pdf, in: outputDirectory)[0]
    try expect([wordPDF, again].allSatisfy { $0.lastPathComponent == pdfURL.lastPathComponent &&
               $0.deletingLastPathComponent() != pdfURL.deletingLastPathComponent() } && wordPDF != again &&
               FileManager.default.fileExists(atPath: pdfURL.path), "Filename collisions use distinct folders and keep the filename")
    let textPages = try Converter.convert(input, to: .jpg, in: outputDirectory)[0]
    try expect([pdfURL, docxURL, roundTrip, wordPDF, images, jpeg, tiff, imagePDF, pdfText, pdfDocx, flowing, again, textPages].allSatisfy {
        $0.standardizedFileURL.path.hasPrefix(outputDirectory.standardizedFileURL.path + "/")
    }, "Every conversion saves within the chosen output folder")
    let sourceContents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    try expect(Set(sourceContents) == Set(["example.txt", "Chosen folder"]), "No converted output is silently saved beside the source")
    do {
        _ = try Converter.convert(input, to: .pdf, in: directory.appendingPathComponent("Missing folder"))
        throw ConversionFailure("A missing output folder must be rejected")
    } catch let error as ConversionFailure {
        try expect(error.message.contains("save folder is unavailable"), "Unavailable destinations never fall back to another location")
    }
    do {
        _ = try Converter.convert(input, to: .pdf, in: input)
        throw ConversionFailure("A file cannot be the output folder")
    } catch let error as ConversionFailure {
        try expect(error.message.contains("save folder is unavailable"), "Destination must be a folder")
    }
    try expect(try String(contentsOf: input, encoding: .utf8) == text, "Original remains byte-for-byte unchanged")
    do { _ = try Converter.convert(input, to: .psd, in: outputDirectory); throw ConversionFailure("PSD export must be rejected") }
    catch let error as ConversionFailure { try expect(error.message.contains("PSD export"), "Unsupported PSD export is explicit") }
    do { _ = try Converter.convert(image, to: .txt, in: outputDirectory); throw ConversionFailure("Image text extraction must be rejected") }
    catch let error as ConversionFailure { try expect(error.message.contains("Text recognition"), "No false OCR promise") }
    try runWidgetConversionTest()
    print("All native conversion checks passed.")
}

// Exercise the same native controls and action handler used by the installed
// widget, without opening a window or changing the user's saved preferences.
func runWidgetConversionTest() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Docenlume-widget-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("widget-check.rtf")
    try Data(#"{\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}\f0\fs48\b Styled widget check\b0\par\fs22 Document layout rendered by the office engine.}"#.utf8).write(to: source)
    let owner = AppDelegate()
    owner.panel = UtilityPanel(contentRect: NSRect(origin: .zero, size: WidgetView.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    owner.widget = WidgetView(owner: owner)
    owner.panel.contentView = owner.widget
    if let wheel = owner.widget.formatButtons.first?.superview {
        let size = wheel.bounds.width
        let center = NSPoint(x: size / 2, y: size / 2)
        let positions: [(OutputFormat, CGFloat, CGFloat)] = [
            (.pdf, 0, -0.35), (.docx, 0.27, -0.22), (.jpg, 0.34, 0.08),
            (.png, 0.15, 0.32), (.tiff, -0.15, 0.32), (.txt, -0.34, 0.08),
            (.zip, -0.27, -0.22)
        ]
        for (format, x, y) in positions {
            let point = NSPoint(x: center.x + size * x, y: center.y + size * y)
            guard (wheel.hitTest(wheel.convert(point, to: wheel.superview)) as? FormatButton)?.format == format else {
                throw ConversionFailure("The \(format.rawValue) segment does not respond at its icon")
            }
        }
        print("PASS: All seven wheel segments receive clicks at their visible positions")
    } else { throw ConversionFailure("Missing format wheel") }
    owner.files = [source]
    owner.outputDirectory = directory
    owner.widget.update()
    guard let pdfButton = owner.widget.formatButtons.first(where: { $0.format == .pdf }) else { throw ConversionFailure("Missing PDF format button") }
    pdfButton.performClick(nil)
    owner.widget.convertButton.performClick(nil)
    let deadline = Date().addingTimeInterval(30)
    while owner.widget.busy && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    guard !owner.widget.busy, let output = owner.outputs.first,
          output.lastPathComponent == "widget-check.pdf", let pdf = PDFDocument(url: output),
          pdf.string?.contains("Styled widget check") == true else { throw ConversionFailure("Native Convert button did not render the office document") }
    let heading = pdf.findString("Styled widget check", withOptions: []).first?.attributedString
    let font = heading?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    guard (font?.pointSize ?? 0) > 20 else { throw ConversionFailure("Styled heading was flattened to plain text") }
    print("PASS: Native Convert button preserves the styled office heading in PDF")
    owner.files = [directory.appendingPathComponent("example.pdf")]
    owner.widget.formatButtons.first(where: { $0.format == .docx })!.performClick(nil)
    guard owner.widget.wordMode == .flowing, !owner.widget.wordModePicker.isHidden,
          !owner.widget.convertButton.title.contains("Set up") else { throw ConversionFailure("PDF to Word must be ready without setup") }
    print("PASS: Native widget defaults to normal paragraphs without account setup")
    let pdfInput = directory.appendingPathComponent("example.pdf")
    try Converter.textPDF("Editable PDF widget check.").write(to: pdfInput)
    owner.outputs = []
    owner.widget.convertButton.performClick(nil)
    let wordDeadline = Date().addingTimeInterval(60)
    while owner.widget.busy && Date() < wordDeadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    guard let wordResult = owner.outputs.first, !owner.widget.busy,
          wordResult.lastPathComponent == "example.docx" else { throw ConversionFailure("PDF to Word widget conversion did not finish") }
    try Converter.validateEditableWord(wordResult, requireFlowing: true)
    print("PASS: PDF → Word works end to end from the native widget without API prompts")

    let otherFolder = directory.appendingPathComponent("Other folder", isDirectory: true)
    try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: false)
    let otherFile = otherFolder.appendingPathComponent(source.lastPathComponent)
    let otherContents = Data("Second file with the same name".utf8)
    try otherContents.write(to: otherFile)
    let largeFile = directory.appendingPathComponent("Large sample.bin")
    let lastByte = Data([0x42])
    try lastByte.write(to: largeFile)
    do {
        let writer = try FileHandle(forWritingTo: largeFile)
        defer { try? writer.close() }
        try writer.seek(toOffset: 110 * 1024 * 1024)
        try writer.write(contentsOf: lastByte)
    }
    owner.files = [source, otherFile, largeFile]
    guard let zipButton = owner.widget.formatButtons.first(where: { $0.format == .zip }) else {
        throw ConversionFailure("Missing Compress button")
    }
    zipButton.performClick(nil)
    owner.widget.convertButton.performClick(nil)
    let zipDeadline = Date().addingTimeInterval(60)
    while owner.widget.busy && Date() < zipDeadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    guard !owner.widget.busy, owner.files.isEmpty, owner.outputs.count == 1,
          let archive = owner.outputs.first, archive.lastPathComponent == "Archive.zip" else {
        throw ConversionFailure("Native Compress button did not save a single ZIP")
    }
    let extracted = directory.appendingPathComponent("Extracted", isDirectory: true)
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-q", archive.path, "-d", extracted.path]
    try unzip.run()
    unzip.waitUntilExit()
    guard unzip.terminationStatus == 0,
          try Data(contentsOf: extracted.appendingPathComponent(source.lastPathComponent)) == Data(contentsOf: source),
          try Data(contentsOf: extracted.appendingPathComponent("Docenlume").appendingPathComponent(otherFile.lastPathComponent)) == otherContents,
          FileManager.default.contentsEqual(atPath: largeFile.path, andPath: extracted.appendingPathComponent(largeFile.lastPathComponent).path),
          try (archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 1024 * 1024 else {
        throw ConversionFailure("ZIP did not compress and preserve all three files")
    }
    print("PASS: Native Compress button preserves duplicate entries and compresses a 110 MiB file into a valid ZIP")

    let photoURL = directory.appendingPathComponent("widget-photo.JPG")
    var seed: UInt32 = 1
    let pixels = Data((0..<(256 * 256 * 4)).map { _ -> UInt8 in
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return UInt8(truncatingIfNeeded: seed >> 24)
    })
    guard let provider = CGDataProvider(data: pixels as CFData),
          let photo = CGImage(width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1024,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        throw ConversionFailure("Couldn’t make the JPEG compression fixture")
    }
    let originalPhoto = try Converter.imageData(photo, to: .jpg)
    try originalPhoto.write(to: photoURL)
    owner.files = [photoURL]
    owner.widget.update()
    guard owner.widget.compressionMode == .reduceSize else { throw ConversionFailure("JPEG should default to Reduce file size") }
    owner.widget.convertButton.performClick(nil)
    let compressionDeadline = Date().addingTimeInterval(20)
    while owner.widget.busy && Date() < compressionDeadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    guard !owner.widget.busy, let compressed = owner.outputs.first, compressed.lastPathComponent == photoURL.lastPathComponent,
          compressed.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
          try Data(contentsOf: compressed).count < originalPhoto.count, try Data(contentsOf: photoURL) == originalPhoto,
          let imageSource = CGImageSourceCreateWithURL(compressed as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil), image.width == 256, image.height == 256 else {
        throw ConversionFailure("Native Compress button didn’t save a smaller JPEG with its original dimensions")
    }
    print("PASS: Native Compress button saves a smaller JPEG without modifying the original")
    owner.panel.close()
}
