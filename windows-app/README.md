# Docenlume for Windows

The Windows source preview uses React Native for Windows and the same editable PDF-to-Word engine as the Mac utility. It has a format wheel, Windows file and folder pickers, and batch conversion. Files are processed locally. A Windows release installer is pending.

## Build and run on Windows x64

Install Node 22.13 or later in the 22 series, Python 3.12 x64, PowerShell 7, and Visual Studio 2026 version 18.6.1 or later with the Desktop development with C++ workload, MSVC v145, and Windows SDK. See [Microsoft’s React Native for Windows setup guide](https://microsoft.github.io/react-native-windows/docs/rnw-dependencies/) for the supporting tools. Install [LibreOffice](https://www.libreoffice.org/download/download-libreoffice/) to convert Word, RTF, and ODT inputs. The app checks the standard LibreOffice install folders and PATH. For a custom installation, set `DOCENLUME_LIBREOFFICE` to the full path of `soffice.com` before launching.

In PowerShell, from the repository root:

```powershell
cd windows-app
npm ci
./build-engine.ps1
npm run build:windows
.\build\app\Release\Docenlume.exe
```

Keep the Release folder together. It contains the app, its JavaScript bundle, and the local conversion engine. Node and Python are needed to build the app. The release build uses the bundled JavaScript and engine.

## Use the wheel

1. Choose **Add files** and select up to 20 files.
2. Choose PDF, DOCX, JPEG, PNG, TIFF, or TXT. For PDF to Word, choose **Editable paragraphs** or **Page layout**.
3. Choose a save folder and click **Convert**. The app keeps each original filename and changes only the extension when the format changes. If a name is already in use, the result goes into a new **Docenlume** subfolder. For multi-page image exports, each numbered page folder contains an image with the original filename and its new extension.

Choose **Compress → Reduce file size** to save a smaller PDF, JPEG, or PNG in the same format. **Create ZIP** bundles selected files of any type into one archive. Both compression modes accept files over 100 MB.

Scanned PDFs can be exported as images. Editable Word conversion requires selectable text. The Windows preview opens in a desktop window. The Mac app has its own menu bar, floating widget, and Finder integration.

The [Windows build workflow](../.github/workflows/windows.yml) checks TypeScript, exercises the conversion engine and its frozen executable, then compiles the Windows x64 desktop app.
