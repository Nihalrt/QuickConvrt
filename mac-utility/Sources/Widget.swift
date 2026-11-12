import AppKit
import QuartzCore

private let accent = NSColor(srgbRed: 0.50, green: 0.87, blue: 0.73, alpha: 1)
private let emerald = NSColor(srgbRed: 0.10, green: 0.66, blue: 0.46, alpha: 1)
private let deepGreen = NSColor(srgbRed: 0.02, green: 0.13, blue: 0.12, alpha: 1)
private let ink = NSColor(srgbRed: 0.90, green: 0.96, blue: 0.93, alpha: 1)
private let mutedInk = NSColor(srgbRed: 0.79, green: 0.87, blue: 0.84, alpha: 1)

private let wheelSize: CGFloat = 312
private let wheelInnerRadius: CGFloat = 64
private let widgetWidth: CGFloat = 356
private let widgetHeight: CGFloat = 552

private func floatingGlass(around content: NSView, in frame: NSRect, radius: CGFloat, tint: NSColor? = nil) -> NSView {
    content.frame = NSRect(origin: .zero, size: frame.size)
    content.autoresizingMask = [.width, .height]
    #if DOCENLUME_NATIVE_GLASS
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView(frame: frame)
        glass.cornerRadius = radius
        glass.style = .regular
        glass.tintColor = tint ?? deepGreen.withAlphaComponent(0.20)
        glass.contentView = content
        return glass
    }
    #endif
    let glass = NSVisualEffectView(frame: frame)
    glass.material = .hudWindow
    glass.state = .active
    glass.blendingMode = .behindWindow
    glass.wantsLayer = true
    glass.layer?.cornerRadius = radius
    glass.layer?.masksToBounds = true
    glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
    glass.layer?.borderWidth = 1
    glass.addSubview(content)
    return glass
}

class FlippedView: NSView { override var isFlipped: Bool { true } }
class UtilityPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = mutedInk, frame: NSRect) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.frame = frame
    return field
}

class FormatButton: NSButton {
    let format: OutputFormat
    private let sector: NSBezierPath
    private let iconCenter: NSPoint
    var picked = false {
        didSet {
            setAccessibilityValue(picked ? "Selected" : nil)
            needsDisplay = true
        }
    }
    private var hovering = false
    private var emphasis: CGFloat = 0
    private var motionTimer: Timer?

    init(_ format: OutputFormat, angle: CGFloat, halfSpan: CGFloat) {
        self.format = format
        let center = NSPoint(x: wheelSize / 2, y: wheelSize / 2)
        let start = angle - halfSpan + 0.005
        let end = angle + halfSpan - 0.005
        let degrees: CGFloat = 180 / .pi
        let shape = NSBezierPath()
        shape.appendArc(withCenter: center, radius: center.x - 1,
                        startAngle: start * degrees, endAngle: end * degrees, clockwise: false)
        shape.line(to: NSPoint(x: center.x + wheelInnerRadius * cos(end), y: center.y + wheelInnerRadius * sin(end)))
        shape.appendArc(withCenter: center, radius: wheelInnerRadius,
                        startAngle: end * degrees, endAngle: start * degrees, clockwise: true)
        shape.close()
        let frame = shape.bounds.integral
        var translation = AffineTransform()
        translation.translate(x: -frame.minX, y: -frame.minY)
        shape.transform(using: translation)
        sector = shape
        let radius = (wheelSize / 2 + wheelInnerRadius) / 2
        iconCenter = NSPoint(x: center.x + cos(angle) * radius - frame.minX,
                             y: center.y + sin(angle) * radius - frame.minY)
        super.init(frame: frame)
        isBordered = false
        title = ""
        let description = format == .zip ? "Compress files" : "Select \(format.rawValue) output"
        setAccessibilityLabel(description)
        toolTip = description
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var focusRingMaskBounds: NSRect { sector.bounds }
    override func drawFocusRingMask() { sector.fill() }

    func containsPoint(_ point: NSPoint) -> Bool { sector.contains(point) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsPoint(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { setHovered(false) }
            needsDisplay = true
        }
    }

    func setHovered(_ flag: Bool) {
        let active = flag && isEnabled
        guard hovering != active else { return }
        hovering = active
        animateEmphasis()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        animateEmphasis()
    }

    private func animateEmphasis() {
        motionTimer?.invalidate()
        motionTimer = nil
        let target: CGFloat = !isEnabled ? 0 : isHighlighted ? -0.35 : hovering ? 1 : 0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || abs(target - emphasis) < 0.001 {
            emphasis = target
            needsDisplay = true
            return
        }
        let start = emphasis
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (CACurrentMediaTime() - began) / 0.18)
            self.emphasis = start + (target - start) * CGFloat(1 - pow(1 - progress, 3))
            self.needsDisplay = true
            if progress >= 1 { timer.invalidate(); self.motionTimer = nil }
        }
        motionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { motionTimer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        let highlight = max(0, emphasis)
        let selectedFill: CGFloat = picked ? 0.24 : 0
        if selectedFill + highlight > 0 {
            let tint = picked ? accent : NSColor.white
            NSGradient(starting: tint.withAlphaComponent(selectedFill + highlight * 0.20),
                       ending: tint.withAlphaComponent(selectedFill * 0.46 + highlight * 0.07))?
                .draw(in: sector, angle: 90)
        }
        (picked ? accent.withAlphaComponent(0.62) : NSColor.white.withAlphaComponent(0.16 + highlight * 0.27)).setStroke()
        sector.lineWidth = 0.8
        sector.stroke()

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: iconCenter.x, yBy: iconCenter.y - highlight * 1.5)
        transform.scale(by: 1 + (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : emphasis * 0.13))
        transform.concat()
        let color = (picked ? accent : ink).withAlphaComponent(isEnabled ? 1 : 0.57)
        let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium).applying(.init(paletteColors: [color]))
        let symbol = NSImage(systemSymbolName: format.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        symbol?.draw(in: NSRect(x: -12, y: -20, width: 24, height: 24), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let text = format.wheelTitle as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: color]
        text.draw(at: NSPoint(x: -text.size(withAttributes: attributes).width / 2, y: 8), withAttributes: attributes)
    }
}

private class OrbitView: FlippedView {
    var formatButtons: [FormatButton] = []
    var receivingFiles = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func updateHover(at point: NSPoint) {
        for button in formatButtons {
            button.setHovered(button.containsPoint(button.convert(point, from: self)))
        }
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) {
        for button in formatButtons { button.setHovered(false) }
    }
    override func viewDidHide() {
        super.viewDidHide()
        for button in formatButtons { button.setHovered(false) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let disk = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSColor.white.withAlphaComponent(0.22).setStroke()
        disk.stroke()
        let inset = bounds.midX - wheelInnerRadius
        let well = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
        NSColor.black.withAlphaComponent(0.16).setFill()
        well.fill()
        (receivingFiles ? accent : NSColor.white.withAlphaComponent(0.25)).setStroke()
        well.lineWidth = receivingFiles ? 2 : 1
        well.stroke()
    }
}

private class LensButton: NSButton {
    var heading = "Add files"
    var symbolName = "arrow.down.to.line"
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    private var circle: NSBezierPath { NSBezierPath(ovalIn: bounds.insetBy(dx: 0.8, dy: 0.8)) }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { circle.fill() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard circle.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = hovered && isEnabled
        let surface = circle
        NSGradient(starting: accent.withAlphaComponent(active ? 0.45 : 0.27),
                   ending: accent.withAlphaComponent(isHighlighted ? 0.26 : 0.12))?
            .draw(in: surface, angle: 90)
        (active ? accent : NSColor.white.withAlphaComponent(0.48)).setStroke()
        surface.stroke()
        let configuration = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium).applying(.init(paletteColors: [ink]))
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        symbol?.draw(in: NSRect(x: bounds.midX - 14, y: 21, width: 28, height: 28), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        drawCentered(heading, y: 56, font: .systemFont(ofSize: 11, weight: .semibold), color: ink)
    }

    private func drawCentered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
        let value = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        value.draw(at: NSPoint(x: bounds.midX - value.size(withAttributes: attributes).width / 2, y: y), withAttributes: attributes)
    }
}

class WidgetView: FlippedView {
    weak var owner: AppDelegate?
    var formatButtons: [FormatButton] = []
    var selection = OutputFormat.pdf
    var busy = false
    var fileLabel: NSTextField!
    var detailLabel: NSTextField!
    var noteLabel: NSTextField!
    var convertButton: NSButton!
    var revealButton: NSButton!
    var pinButton: NSButton!
    var destinationButton: NSButton!
    var wordModePicker: NSPopUpButton!
    private var orbit: OrbitView!
    private var lens: LensButton!
    private var spinner: NSProgressIndicator!
    private var wordGlass: NSView!
    private var compressionGlass: NSView!
    private var compressionPicker: NSPopUpButton!
    var compressionModeOverride: CompressionMode?
    private var destinationGlass: NSView!
    private var convertGlass: NSView!
    private var footerGlass: NSView!
    private var receivingFiles = false

    static let size = NSSize(width: widgetWidth, height: widgetHeight)

    init(owner: AppDelegate) {
        self.owner = owner
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        appearance = NSAppearance(named: .darkAqua)
        registerForDraggedTypes([.fileURL])

        let toolbar = FlippedView()
        let brand = NSImageView(frame: NSRect(x: 14, y: 9, width: 16, height: 16))
        brand.image = NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: nil)
        brand.contentTintColor = accent
        toolbar.addSubview(brand)
        toolbar.addSubview(label("Docenlume", size: 12, weight: .semibold, color: ink,
                                 frame: NSRect(x: 37, y: 9, width: 82, height: 17)))
        let paste = iconButton("clipboard", frame: NSRect(x: 117, y: 4, width: 26, height: 26), action: #selector(pasteFiles))
        paste.toolTip = "Paste copied files from Finder (⌘V)"
        paste.setAccessibilityLabel("Paste copied files")
        toolbar.addSubview(paste)
        pinButton = iconButton("pin", frame: NSRect(x: 147, y: 4, width: 26, height: 26), action: #selector(pin))
        pinButton.toolTip = "Keep the widget floating over other apps"
        pinButton.setAccessibilityLabel("Pin widget")
        toolbar.addSubview(pinButton)
        let close = iconButton("xmark", frame: NSRect(x: 177, y: 4, width: 26, height: 26), action: #selector(closeWidget))
        close.toolTip = "Hide widget (Esc)"
        close.setAccessibilityLabel("Hide widget")
        toolbar.addSubview(close)
        addSubview(floatingGlass(around: toolbar, in: NSRect(x: 71, y: 10, width: 214, height: 34), radius: 17))

        orbit = OrbitView()
        let wheelFrame = NSRect(x: (widgetWidth - wheelSize) / 2, y: 58, width: wheelSize, height: wheelSize)
        addSubview(floatingGlass(around: orbit, in: wheelFrame, radius: wheelSize / 2,
                                tint: deepGreen.withAlphaComponent(0.23)))
        let formats: [OutputFormat] = [.pdf, .docx, .jpg, .png, .tiff, .txt, .zip]
        let span = 2 * CGFloat.pi / CGFloat(formats.count)
        for (index, format) in formats.enumerated() {
            let button = FormatButton(format, angle: CGFloat(index) * span - .pi / 2, halfSpan: span / 2)
            button.target = self
            button.action = #selector(pickFormat(_:))
            orbit.addSubview(button)
            formatButtons.append(button)
        }
        orbit.formatButtons = formatButtons

        let lensSize: CGFloat = 94
        let lensInset = (wheelSize - lensSize) / 2
        let lensFrame = NSRect(x: lensInset, y: lensInset, width: lensSize, height: lensSize)
        lens = LensButton(frame: lensFrame)
        lens.isBordered = false
        lens.target = self
        lens.action = #selector(choose)
        lens.toolTip = "Choose files to convert"
        orbit.addSubview(lens)

        let status = FlippedView()
        fileLabel = label("No files selected", size: 11, weight: .semibold, color: ink,
                          frame: NSRect(x: 17, y: 7, width: 262, height: 16))
        fileLabel.lineBreakMode = .byTruncatingMiddle
        status.addSubview(fileLabel)
        detailLabel = label("Drop files, browse, or paste from Finder", size: 10,
                            frame: NSRect(x: 17, y: 24, width: 262, height: 15))
        detailLabel.lineBreakMode = .byTruncatingTail
        status.addSubview(detailLabel)
        addSubview(floatingGlass(around: status, in: NSRect(x: 30, y: 385, width: 296, height: 46), radius: 23))

        let wordRow = FlippedView()
        wordRow.addSubview(label("Word layout", size: 10, weight: .medium, color: ink,
                                 frame: NSRect(x: 17, y: 9, width: 76, height: 17)))
        wordModePicker = NSPopUpButton(frame: NSRect(x: 90, y: 3, width: 192, height: 26), pullsDown: false)
        wordModePicker.addItems(withTitles: WordConversionMode.allCases.map(\.rawValue))
        wordModePicker.target = self
        wordModePicker.action = #selector(wordModeChanged)
        wordModePicker.font = .systemFont(ofSize: 10)
        wordModePicker.setAccessibilityLabel("PDF to Word layout mode")
        wordRow.addSubview(wordModePicker)
        wordGlass = floatingGlass(around: wordRow, in: NSRect(x: 30, y: 439, width: 296, height: 32), radius: 16)
        addSubview(wordGlass)

        let compressionRow = FlippedView()
        compressionRow.addSubview(label("Compression", size: 10, weight: .medium, color: ink,
                                        frame: NSRect(x: 17, y: 9, width: 76, height: 17)))
        compressionPicker = NSPopUpButton(frame: NSRect(x: 90, y: 3, width: 192, height: 26), pullsDown: false)
        compressionPicker.addItems(withTitles: CompressionMode.allCases.map(\.rawValue))
        compressionPicker.target = self
        compressionPicker.action = #selector(compressionModeChanged)
        compressionPicker.font = .systemFont(ofSize: 10)
        compressionPicker.setAccessibilityLabel("Compression mode")
        compressionRow.addSubview(compressionPicker)
        compressionGlass = floatingGlass(around: compressionRow, in: NSRect(x: 30, y: 439, width: 296, height: 32), radius: 16)
        addSubview(compressionGlass)

        let destinationRow = FlippedView()
        destinationRow.addSubview(label("Save to", size: 10, weight: .medium, color: ink,
                                        frame: NSRect(x: 17, y: 9, width: 43, height: 17)))
        destinationButton = NSButton(title: "Choose folder…", target: self, action: #selector(chooseDestination))
        destinationButton.frame = NSRect(x: 64, y: 3, width: 218, height: 26)
        destinationButton.bezelStyle = .rounded
        destinationButton.font = .systemFont(ofSize: 10)
        destinationButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        destinationButton.imagePosition = .imageLeading
        destinationButton.cell?.lineBreakMode = .byTruncatingMiddle
        destinationButton.setAccessibilityLabel("Choose where to save converted files")
        destinationRow.addSubview(destinationButton)
        destinationGlass = floatingGlass(around: destinationRow, in: NSRect(x: 30, y: 439, width: 296, height: 32), radius: 16)
        addSubview(destinationGlass)

        let convertRow = FlippedView()
        convertButton = NSButton(title: "Choose files to begin", target: self, action: #selector(convertSelectedFiles))
        convertButton.frame = NSRect(x: 0, y: 0, width: 244, height: 38)
        convertButton.isBordered = false
        convertButton.font = .systemFont(ofSize: 12, weight: .semibold)
        convertRow.addSubview(convertButton)
        spinner = NSProgressIndicator(frame: NSRect(x: 22, y: 12, width: 14, height: 14))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        convertRow.addSubview(spinner)
        convertGlass = floatingGlass(around: convertRow, in: NSRect(x: 56, y: 480, width: 244, height: 38),
                                    radius: 19, tint: emerald.blended(withFraction: 0.66, of: deepGreen)?.withAlphaComponent(0.38))
        addSubview(convertGlass)

        noteLabel = label("", size: 9, color: ink, frame: NSRect(x: 19, y: 2, width: 258, height: 18))
        noteLabel.alignment = .center
        revealButton = NSButton(title: "Show in Finder ↗", target: self, action: #selector(reveal))
        revealButton.frame = NSRect(x: 0, y: 0, width: 296, height: 22)
        revealButton.isBordered = false
        revealButton.font = .systemFont(ofSize: 10, weight: .medium)
        revealButton.contentTintColor = accent
        let footer = FlippedView()
        footer.addSubview(noteLabel)
        footer.addSubview(revealButton)
        footerGlass = floatingGlass(around: footer, in: NSRect(x: 30, y: 524, width: 296, height: 22), radius: 11)
        addSubview(footerGlass)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    func iconButton(_ name: String, frame: NSRect, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: name)!, target: self, action: action)
        button.isBordered = false; button.frame = frame; button.contentTintColor = mutedInk
        return button
    }
    func update(message: String? = nil, failed: Bool = false) {
        for button in formatButtons { button.picked = button.format == selection; button.isEnabled = !busy }
        if busy { receivingFiles = false }
        updateOrbit()
        let files = owner?.files ?? []
        let pending = Converter.filesNeedingConversion(files, to: selection)
        let pdfToWord = selection == .docx && files.contains { $0.pathExtension.lowercased() == "pdf" }
        wordGlass.isHidden = !pdfToWord
        wordModePicker.isHidden = !pdfToWord
        wordModePicker.isEnabled = !busy
        let showCompression = selection == .zip && !files.isEmpty
        compressionGlass.isHidden = !showCompression
        compressionPicker.isEnabled = !busy
        compressionPicker.selectItem(withTitle: compressionMode.rawValue)
        let offset: CGFloat = pdfToWord || showCompression ? 40 : 0
        destinationGlass.frame.origin.y = 439 + offset
        convertGlass.frame.origin.y = 480 + offset
        convertGlass.isHidden = files.isEmpty && !busy
        let hasOutputs = owner?.outputs.isEmpty == false
        footerGlass.frame.origin.y = convertGlass.isHidden ? 480 : 524 + offset
        let height = convertGlass.isHidden ? (hasOutputs ? 510 : 480) : widgetHeight + offset
        if frame.height != height {
            let top = owner?.panel.frame.maxY
            setFrameSize(NSSize(width: widgetWidth, height: height))
            owner?.panel.setContentSize(NSSize(width: widgetWidth, height: height))
            if let top, let panel = owner?.panel { panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height)) }
        }
        let skipped = files.count - pending.count
        let sameFormatMessage = pending.isEmpty ? "Already \(selection.rawValue). Pick another format." : "\(skipped) already \(selection.rawValue) · Will skip \(skipped == 1 ? "it" : "them")"
        fileLabel.stringValue = files.isEmpty ? "No files selected" : files.count == 1 ? files[0].lastPathComponent : "\(files.count) files selected"
        detailLabel.stringValue = message ?? (files.isEmpty ? "Drop files, browse, or paste from Finder" : skipped > 0 ? sameFormatMessage : owner?.outputDirectory == nil ? "Choose a save folder." : "")
        detailLabel.textColor = failed ? .systemRed : mutedInk
        destinationButton.title = owner?.outputDirectory.map { $0.path.replacingOccurrences(of: NSHomeDirectory() + "/", with: "~/") } ?? "Choose folder…"
        destinationButton.toolTip = owner?.outputDirectory?.path ?? "Choose where to save converted files"
        destinationButton.isEnabled = !busy
        convertButton.isEnabled = !busy && !pending.isEmpty
        if selection == .zip {
            convertButton.title = busy ? "Compressing…" : "\(compressionMode.rawValue)  →"
        } else {
            convertButton.title = busy ? "Converting on your Mac…" : files.isEmpty ? "Choose files to begin" : pending.isEmpty ? "Already \(selection.rawValue) — pick another format" : "Convert \(pending.count == 1 ? "to" : "\(pending.count) files to") \(selection.rawValue)  →"
        }
        convertButton.contentTintColor = convertButton.isEnabled || busy ? ink : mutedInk
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        pinButton.contentTintColor = owner?.pinned == true ? accent : mutedInk
        pinButton.image = NSImage(systemSymbolName: owner?.pinned == true ? "pin.fill" : "pin", accessibilityDescription: "Pin widget")
        revealButton.isHidden = !hasOutputs
        if pdfToWord {
            noteLabel.stringValue = wordMode == .layout ? "Uses positioned text boxes" : "Editable paragraphs, lists, and tables"
        } else if showCompression && compressionMode == .reduceSize {
            noteLabel.stringValue = "PDF and JPEG image quality may be reduced."
        } else {
            noteLabel.stringValue = ""
        }
        noteLabel.isHidden = hasOutputs || noteLabel.stringValue.isEmpty
        footerGlass.isHidden = noteLabel.isHidden && !hasOutputs
    }

    private func updateOrbit() {
        let fileCount = owner?.files.count ?? 0
        let outputCount = owner?.outputs.count ?? 0
        orbit.receivingFiles = receivingFiles
        lens.isEnabled = !busy
        if receivingFiles {
            lens.heading = "Release to add"
            lens.symbolName = "arrow.down.circle.fill"
        } else if busy {
            lens.heading = selection == .zip ? "Compressing" : "Converting"
            lens.symbolName = "arrow.triangle.swap"
        } else if fileCount > 0 {
            lens.heading = fileCount == 1 ? "1 file ready" : "\(fileCount) files ready"
            lens.symbolName = "doc.on.doc"
        } else if outputCount > 0 {
            lens.heading = "Files saved"
            lens.symbolName = "checkmark.circle"
        } else {
            lens.heading = "Add files"
            lens.symbolName = "arrow.down.to.line"
        }
        lens.setAccessibilityLabel(busy ? "\(lens.heading) files" : "\(lens.heading). Choose files")
        lens.needsDisplay = true
    }
    @objc func pickFormat(_ sender: FormatButton) {
        if let event = NSApp.currentEvent, event.type == .leftMouseUp, event.window === window,
           !sender.containsPoint(sender.convert(event.locationInWindow, from: nil)) { return }
        selection = sender.format
        update()
    }
    @objc func choose() { owner?.chooseFiles() }
    var wordMode: WordConversionMode { WordConversionMode.allCases[max(0, wordModePicker.indexOfSelectedItem)] }
    @objc func wordModeChanged() { update() }
    var compressionMode: CompressionMode {
        compressionModeOverride ?? .preferred(for: owner?.files ?? [])
    }
    @objc func compressionModeChanged() {
        compressionModeOverride = compressionPicker.titleOfSelectedItem.flatMap(CompressionMode.init(rawValue:))
        update()
    }
    @objc func chooseDestination() { owner?.chooseOutputFolder() }
    @objc func pasteFiles() { owner?.receivePasteboard(.general) }
    @objc func convertSelectedFiles() { owner?.convertSelection() }
    @objc func reveal() { if let outputs = owner?.outputs { NSWorkspace.shared.activateFileViewerSelecting(outputs) } }
    @objc func pin() { owner?.pinned.toggle(); update() }
    @objc func closeWidget() { window?.orderOut(nil) }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" { pasteFiles() }
        else if event.keyCode == 53 { closeWidget() }
        else { super.keyDown(with: event) }
    }
    private func trackDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        let acceptsDrop = !busy && sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        if receivingFiles != acceptsDrop {
            receivingFiles = acceptsDrop
            updateOrbit()
        }
        return acceptsDrop ? .copy : []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { trackDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { trackDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        receivingFiles = false
        updateOrbit()
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = trackDrop(sender) == .copy
        receivingFiles = false
        updateOrbit()
        guard accepted else { return false }
        owner?.receivePasteboard(sender.draggingPasteboard)
        return true
    }
}
