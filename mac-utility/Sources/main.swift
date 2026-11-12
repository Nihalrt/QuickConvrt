import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: UtilityPanel!
    var widget: WidgetView!
    var files: [URL] = []
    var outputs: [URL] = []
    var outputDirectory: URL? = UserDefaults.standard.string(forKey: "outputDirectoryPath").map { URL(fileURLWithPath: $0, isDirectory: true) }
    var showingPicker = false
    var pinned = false
    var hotKey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var localMonitor: Any?
    var globalMonitor: Any?
    var pendingFiles: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let root = NSMenuItem(); menu.addItem(root)
        let appMenu = NSMenu(); root.submenu = appMenu
        appMenu.addItem(withTitle: "About Docenlume", action: #selector(showHelp), keyEquivalent: "")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let services = NSMenu(); servicesItem.submenu = services; appMenu.addItem(servicesItem); NSApp.servicesMenu = services
        appMenu.addItem(withTitle: "Quit Docenlume", action: #selector(quit), keyEquivalent: "q")
        NSApp.mainMenu = menu

        panel = UtilityPanel(contentRect: NSRect(origin: .zero, size: WidgetView.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.title = "Docenlume"
        widget = WidgetView(owner: self); panel.contentView = widget
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: "Docenlume")
            button.toolTip = "Docenlume · ⌃⌥⌘E · Right-click for options"
            button.target = self; button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        registerShortcut()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, event.window !== self.panel && !self.pinned && !self.showingPicker && self.panel.attachedSheet == nil { self.panel.orderOut(nil) }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, !self.pinned, !self.showingPicker, self.panel.attachedSheet == nil else { return }; self.panel.orderOut(nil)
        }
        // Service calls may arrive as soon as the provider is assigned.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        if !pendingFiles.isEmpty { acceptFiles(pendingFiles); pendingFiles = [] }
        else { showWidget() }
    }

    @objc func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Show widget    ⌃⌥⌘E", action: #selector(showWidget), keyEquivalent: "")
            menu.addItem(withTitle: "Choose files…", action: #selector(chooseFiles), keyEquivalent: "")
            menu.addItem(withTitle: "Use copied files", action: #selector(pasteFiles), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "How to use Docenlume", action: #selector(showHelp), keyEquivalent: "")
            menu.addItem(withTitle: "Quit Docenlume", action: #selector(quit), keyEquivalent: "q")
            for item in menu.items { item.target = self }
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else if panel.isVisible { panel.orderOut(nil) }
        else { showWidget() }
    }

    @objc func showWidget() {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let anchor = statusItem.button?.window?.frame
        let visible = screen.visibleFrame
        let width = panel.frame.width
        let x = min(max((anchor?.midX ?? visible.midX) - width / 2, visible.minX + 10), visible.maxX - width - 10)
        let y = max(visible.minY + 10, (anchor?.minY ?? visible.maxY) - panel.frame.height - 10)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(widget)
    }

    @objc func chooseFiles() {
        presentFilePicker()
    }

    private func presentFilePicker(in folder: URL? = nil, then completion: (() -> Void)? = nil) {
        guard !widget.busy, !showingPicker else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose files to convert"
        picker.prompt = "Use these files"
        picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = true
        picker.directoryURL = folder
        picker.level = .floating
        showingPicker = true
        picker.begin { [weak self] response in
            guard let self else { return }
            self.showingPicker = false
            if response == .OK {
                self.acceptFiles(picker.urls)
                completion?()
            } else { self.showWidget() }
        }
    }

    func chooseOutputFolder(then completion: (() -> Void)? = nil) {
        guard !widget.busy, !showingPicker else { return }
        let picker = NSOpenPanel()
        picker.title = "Where should converted files be saved?"
        picker.message = "Choose a save folder. Docenlume remembers it; you can change it anytime using Save to."
        picker.prompt = "Save here"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.directoryURL = outputDirectory ?? files.first?.deletingLastPathComponent()
        showWidget()
        showingPicker = true
        picker.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            self.showingPicker = false
            guard response == .OK, let folder = picker.url else {
                self.widget.update(message: "Folder selection cancelled. Save folder unchanged.")
                return
            }
            self.outputDirectory = folder
            UserDefaults.standard.set(folder.path, forKey: "outputDirectoryPath")
            self.widget.update()
            completion?()
        }
    }

    func acceptFiles(_ urls: [URL]) {
        guard widget != nil else { pendingFiles = urls; return }
        guard !widget.busy else { return }
        let local = Array(NSOrderedSet(array: urls.filter(\.isFileURL))) as? [URL] ?? []
        guard !local.isEmpty else { widget.update(message: "Copy files in Finder first, then paste here.", failed: true); return }
        files = Array(local.prefix(20))
        widget.compressionModeOverride = nil
        outputs = []
        showWidget()
        widget.update(message: local.count > 20 ? "Using the first 20 files. Convert larger batches separately." : nil)
    }

    func receivePasteboard(_ pasteboard: NSPasteboard) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            acceptFiles(urls)
        } else if let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            acceptFiles(paths.map { URL(fileURLWithPath: $0) })
        } else { showWidget(); widget.update(message: "Copy files in Finder first, then paste here.", failed: true) }
    }

    @objc func pasteFiles() { receivePasteboard(.general) }

    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receivePasteboard(pasteboard)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        acceptFiles(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func convertSelection() {
        guard !widget.busy, !showingPicker, !files.isEmpty else { return }
        let format = widget.selection
        let compressing = format == .zip
        let creatingZIP = compressing && widget.compressionMode == .zip
        let wordMode = widget.wordMode
        let selected = Converter.filesNeedingConversion(files, to: format)
        let skipped = files.count - selected.count
        guard !selected.isEmpty else { widget.update(); return }
        guard let outputDirectory, (try? Converter.validateOutputDirectory(outputDirectory)) != nil else {
            chooseOutputFolder { [weak self] in self?.convertSelection() }
            return
        }
        widget.busy = true; outputs = []; widget.update(message: compressing ? "Compressing…" : "Converting…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [URL] = [], errors: [String] = [], succeeded: [URL] = []
            var blockedSource: URL?
            var blockedDestination = false
            let groups = creatingZIP ? [selected] : selected.map { [$0] }
            for group in groups {
                do {
                    if creatingZIP {
                        results.append(try Converter.compress(group, in: outputDirectory))
                    } else if compressing {
                        results.append(try Converter.reduceSize(group[0], in: outputDirectory))
                    } else {
                        results += try Converter.convert(group[0], to: format, in: outputDirectory, wordMode: wordMode)
                    }
                    succeeded += group
                } catch {
                    let archiveInput = error as? ArchiveInputError
                    let accessError = ConversionAccessError.classify(archiveInput?.cause ?? error, in: outputDirectory)
                    if accessError == .source, blockedSource == nil { blockedSource = archiveInput?.file ?? group[0] }
                    if accessError == .destination { blockedDestination = true }
                    let name = archiveInput?.file.lastPathComponent ?? (creatingZIP ? "ZIP" : group[0].lastPathComponent)
                    errors.append("\(name): \((accessError as Error? ?? archiveInput?.cause ?? error).localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.outputs = results
                self.files.removeAll { succeeded.contains($0) }
                self.widget.busy = false
                let skippedMessage = skipped > 0 ? " · \(skipped) already \(format.rawValue), skipped" : ""
                let successMessage = skipped > 0 ? "\(succeeded.count) converted\(skippedMessage)" : "Done. \(succeeded.count) file\(succeeded.count == 1 ? "" : "s") saved to your chosen folder."
                let message: String
                if creatingZIP {
                    message = results.first.map { "Saved \($0.lastPathComponent)." } ?? "Couldn’t create the ZIP archive."
                } else if compressing {
                    let saved = succeeded.count == 1 ? "1 smaller copy saved" : "\(succeeded.count) smaller copies saved"
                    message = errors.isEmpty ? saved : "\(saved) · \(errors.count) couldn’t be reduced"
                } else {
                    message = errors.isEmpty ? successMessage : "\(succeeded.count) converted · \(errors.count) couldn’t convert\(skippedMessage)"
                }
                self.widget.update(message: message, failed: !errors.isEmpty)
                if errors.isEmpty { return }
                let details = errors.joined(separator: "\n\n")
                if let blockedSource {
                    self.showNotice("File access needed", details, actionTitle: "Choose Files and Retry") { [weak self] in
                        self?.presentFilePicker(in: blockedSource.deletingLastPathComponent()) { [weak self] in
                            self?.convertSelection()
                        }
                    }
                } else if blockedDestination {
                    self.showNotice("Save folder access needed", details, actionTitle: "Choose Save Folder") { [weak self] in
                        self?.chooseOutputFolder { [weak self] in self?.convertSelection() }
                    }
                } else { self.showNotice(compressing ? "Compression couldn’t finish" : "Conversion couldn’t finish", details) }
            }
        }
    }

    func registerShortcut() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { if owner.panel.isVisible { owner.panel.orderOut(nil) } else { owner.showWidget() } }
            return noErr
        }, 1, &spec, pointer, &eventHandler)
        let id = EventHotKeyID(signature: OSType(0x45434E56), id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_E), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { statusItem.button?.toolTip = "Docenlume · Shortcut unavailable; click to open" }
    }

    @objc func showHelp() {
        showNotice("Docenlume lives where you work", "1. Select files in Finder → right-click → Services → Convert with Docenlume.\n\n2. Or copy files in Finder, click the menu-bar icon, and paste (⌘V). You can also drop files directly onto the widget.\n\n3. Pick a format and choose a folder using Save to, then Convert. Docenlume remembers your preferred folder. If none is set, Convert asks where to save first. Multi-page images go into a new subfolder at that destination.\n\n⌃⌥⌘E opens the widget from other apps. Pin it to keep it floating. Escape hides it.\n\nSupported: PDF; TXT/MD/CSV/JSON; DOC/DOCX/RTF/ODT; and macOS-readable images. Word → PDF and office → page images use the local document renderer to retain document layout, tables, images, and styling. PDF → Word defaults to Editable paragraphs: normal Word paragraphs, native bullet lists, hyperlinks and tables. Text can reflow when edited. It works entirely offline. Short side-by-side labels use tabs instead of artificial columns. Complex pages may reflow differently. Page layout (text boxes) is an explicit alternative for equations and fixed designs; it retains page positions but uses text boxes. Scans and exact semantic equation reconstruction are not supported. Diagrams remain graphics; page text is never replaced with screenshots. Scanned PDFs need OCR. PDF → images renders at up to 300 dpi. TXT output is plain text by definition. PSD uses a flattened preview; PSD export is unavailable.\n\nFor Finder Services to appear, keep Docenlume in Applications and open it once. If hidden, enable it in System Settings → Keyboard → Keyboard Shortcuts → Services → Files and Folders.\n\nThis local development build is ad-hoc signed, not notarized for distribution.")
    }

    func showNotice(_ title: String, _ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        if let actionTitle {
            alert.addButton(withTitle: actionTitle)
            alert.addButton(withTitle: "Cancel")
        } else { alert.addButton(withTitle: "Got it") }
        showWidget()
        alert.beginSheetModal(for: panel) { response in
            if response == .alertFirstButtonReturn { action?() }
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
}

if CommandLine.arguments.contains("--self-test") {
    do { try runSelfTest() } catch { fputs("SELF TEST FAILED: \(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--convert" {
    do {
        let source = URL(fileURLWithPath: CommandLine.arguments[2])
        guard let format = OutputFormat.allCases.first(where: { $0.ext == CommandLine.arguments[3].lowercased() }) else { throw ConversionFailure("Unknown output format.") }
        let destination = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
        for output in try Converter.convert(source, to: format, in: destination) { print(output.path) }
    } catch { fputs("Conversion failed: \(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--pdf-to-word" {
    do {
        let source = URL(fileURLWithPath: CommandLine.arguments[2])
        let destination = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        for output in try Converter.convert(source, to: .docx, in: destination) { print(output.path) }
    } catch { fputs("Conversion failed: \(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--pdf-to-word") {
    fputs("Use --pdf-to-word SOURCE OUTPUT_FOLDER for local conversion.\n", stderr)
    exit(1)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
