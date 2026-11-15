# QuickConvrt for Mac

A native menu-bar utility with a circular format picker, Finder Services, drag and drop, and a global shortcut. All conversions run locally. No account, API credentials, subscription, or upload is needed.

## Use

Open `/Applications/QuickConvrt.app`. Click the two-arrow menu-bar icon or press **⌃⌥⌘E**. Select files in Finder → right-click → **Services → Convert with QuickConvrt**, or drop/paste copied files into the widget. Choose an output format, choose a **Save to** folder, and click **Convert**.

The destination is remembered. Same-format inputs are skipped; existing files are never overwritten. The pin keeps the widget above other apps. Escape hides it. Right-click the menu-bar icon to quit.

QuickConvrt keeps the original filename and changes only the extension when the format changes. If a name is already in use, the result goes into a new **QuickConvrt** subfolder. When one document produces several page images, each numbered page folder contains an image with the original filename and its new extension.

Choose **Compress → Reduce file size** for a smaller PDF, JPEG, or PNG. Choose **Create ZIP** to bundle files of any type and preserve their contents. Both modes accept files over 100 MB. Savings vary with the input. Some files are already compressed.

## Document formatting

PDF → Word retains each embedded font subset's full identity, including its subset prefix. Different subsets of one face can assign different outlines to the same glyph index; they must never be merged by family name. PDF names and binary font names are matched only through unambiguous aliases. Negative continuation indexes for multi-character glyphs are never treated as actual glyphs.

For cmap-less Carlito/Caladea subsets, the converter can recover the complete face already bundled with the office engine. Every original outline and advance must match exactly before this is allowed. This restores normal Unicode letters and shaping for combinations such as ft, ti, fi, and ffi, without substituting a similar font or using page images. Genuine conversion failures still display an error; the misleading “different format” alert heading was replaced.

Run the focused font regressions with `build/pdf-engine-env/bin/python Engine/test_pdf_editable.py`.

**Word → PDF** renders the original DOCX/DOC/RTF/ODT package through a bundled local LibreOffice engine. Tables, embedded images, styling, headers, footers, and page layout go through the renderer rather than plain-text extraction. Office → page images uses that same PDF. Fonts missing from this Mac may be substituted; Word-specific features can differ from Microsoft Word.

**PDF → Word** has two local modes:

- **Editable paragraphs** is the default for the widget, Finder Services, and CLI. Ordinary single-column documents are reconstructed as normal Word paragraphs, native bullet lists, formatted runs, right-aligned tabs, and real hyperlinks. Wrapped lines become one paragraph and can reflow when edited. Short job/location or degree/date rows do not become newspaper columns. Known metrically compatible office font families are mapped to Word font names. Complex tables and illustrated pages use the local table reconstruction engine, with corrected hyperlink markup. The output is rejected if text boxes are present or source text is missing or duplicated. Scans require OCR, and mathematical font layouts require the explicit page-layout option.
- **Page layout (text boxes)** is an explicit alternative for equations and fixed page designs. It retains editable text positions, colors and embedded source fonts when permitted. Tables keep their appearance, and diagrams remain artwork. Text is removed from the artwork layer before rendering; full-page screenshots do not conceal duplicate text. Font subsets and large TeX glyphs use the verified repair path introduced in v0.3.1. Large edits do not reflow between boxes, and equations are not native Word equation objects.

Every PDF → Word result is checked for actual editable text and rendered back to PDF locally. Paragraph mode also rejects text boxes and incomplete text. Page-layout mode checks the page count. These checks catch unusable files; they do not prove exact visual fidelity for arbitrary PDFs.

Editable paragraphs preserve common text underlines, highlights, and first-line indents in browser-generated PDFs. If you still have the original editable document, export it directly to Word to retain its original document structure.

**PDF → JPEG/PNG/TIFF** exports the visible crop with page rotation at up to 300 dpi, within the image size limits, and records DPI metadata for physical print size. PNG/TIFF are lossless outputs. JPEG uses high quality and a white background for transparency.

## Supported routes and limits

| Input | Output |
| --- | --- |
| DOCX, DOC, RTF, ODT | Layout-rendered PDF and page images; DOCX; plain TXT |
| PDF with selectable text | Editable DOCX; JPEG/PNG/TIFF pages; TXT |
| Scanned PDF | JPEG/PNG/TIFF pages; editable Word requires OCR and is explicitly rejected |
| macOS-readable JPEG, PNG, TIFF, HEIC/HEIF, WebP, GIF, BMP, flattened PSD previews | PDF, JPEG, PNG, TIFF |
| UTF-8/UTF-16 TXT, MD, CSV, JSON, XML, YAML, logs | Plain contents as PDF, DOCX, TXT, page images |

PSD export and layered PSD editing are unavailable. Animation uses the first frame. TXT has no rich formatting by definition. Password-protected PDFs are unsupported. Format conversion accepts files up to 100 MB and PDFs up to 100 pages. Compression accepts larger files and longer PDFs. Format conversion and **Reduce file size** accept images up to 100 megapixels. Batches are limited to 20 inputs. PDF images are capped at 8192 pixels per edge and 32 megapixels per page. Word pages have a 22-inch limit.

This is a tested local converter for these routes, not a guarantee of exact conversion between every possible format. In particular, scans require OCR, semantic equation reconstruction is not included, and document reflow can change layout.

## Build and install locally

Build on an Apple Silicon Mac with Xcode Command Line Tools, Python 3.12, and the Apple Silicon version of [LibreOffice](https://www.libreoffice.org/download/download-libreoffice/) installed in Applications. The resulting app bundles the conversion engines.

```sh
cd mac-utility
python3.12 -m venv build/pdf-engine-env
build/pdf-engine-env/bin/python -m pip install -r Engine/requirements.txt
./stage-office-engine.sh /Applications/LibreOffice.app
./build-engine.sh
./build.sh
build/QuickConvrt.app/Contents/MacOS/QuickConvrt --self-test
```

Open `mac-utility/build` in Finder, drag **QuickConvrt.app** into **Applications**, and open it. This build is for local development. See the [release checklist](../RELEASING.md) to prepare a public download.

The renderer is packaged at `Contents/Resources/OfficeEngine/LibreOfficeDev.app`. The local PDF helper and its runtime are at `Contents/Resources/PDFEngine`. Its source is included in `PDFEngine/source/`. Third-party licenses are in `PDFEngine/licenses/` and in the nested LibreOffice bundle. See the [third-party notices](../THIRD-PARTY.md) for the release dependencies and source links.

CLI examples:

```sh
build/QuickConvrt.app/Contents/MacOS/QuickConvrt --convert /path/input.docx pdf /path/output-folder
build/QuickConvrt.app/Contents/MacOS/QuickConvrt --pdf-to-word /path/input.pdf /path/output-folder
```

## Verification

The native regression checks exercise the paragraph default, rejection of text boxes, widget conversion, both Word modes, editable text, Unicode, chosen destinations, no overwrite, same-format skipping, file access errors, and cropped or rotated image exports with DPI metadata. Run `build/pdf-engine-env/bin/python -m unittest discover -s Engine` for focused reconstruction tests.

## Source

- `Sources/Converter.swift`: supported routes, safe naming, crop/rotation handling, image quality.
- `Sources/OfficeEngine.swift`: original office document rendering with an isolated profile and timeout.
- `Sources/EditableWord.swift`: local PDF reconstruction, editable-text validation, and output render checks.
- `Engine/pdf_editable.py`: positioned text, font repair/normalization, separate artwork, and paragraph-engine dispatch.
- `Engine/flowing_word.py`: native paragraphs, lists, hyperlinks, short side-by-side labels, and table reconstruction without text boxes.
- `Sources/main.swift`: menu bar, Finder Services, shortcut, file/destination selection, background conversion.
- `Sources/Widget.swift`: circular picker and local Word layout modes.
- `Sources/SelfTest.swift`: native regression checks.
