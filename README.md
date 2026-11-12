# Docenlume

<img src="mac-utility/Assets/Docenlume.png" alt="Docenlume app icon" width="128">

Docenlume converts documents and images locally. Pick a file, choose a format from the wheel, and save the result to a folder you choose. The Mac utility lives in the menu bar. The React Native Windows source preview runs in a desktop window.

## Install on macOS

Docenlume will be free to download and use. It targets **Apple Silicon Macs (M1 or newer) running macOS 13 or later**. To check your Mac, choose **Apple menu → About This Mac** and look for an Apple chip and the macOS version.

**The Mac installer is awaiting Apple notarization.** You can [build the app from source](mac-utility/README.md#build-and-install-locally) today. The installer ZIP will appear on the [Docenlume Releases page](https://github.com/Nihalrt/Docenlume/releases) when it is ready.

Once the Mac release is published:

1. Open the public GitHub Releases page and select the latest Mac release. Under **Assets**, download **Docenlume-Mac-arm64-v0.4.13.zip** for the first release. On newer releases, choose the app ZIP with the matching version number.
2. In Finder, open **Downloads** and double-click the ZIP if your browser has not already extracted it.
3. Drag **Docenlume.app** into **Applications**. Open it from **Applications** and click **Open** if macOS asks you to confirm the first launch.
4. Click the **Docenlume** icon in the menu bar or press **Control–Option–Command–E**. Add a file, choose an output format and save folder, then click **Convert**.

The app includes its conversion engines. You can use it without a Docenlume account, subscription, or separate Word, LibreOffice, or Python installation.

## Build on Windows

See [Build and run on Windows x64](windows-app/README.md#build-and-run-on-windows-x64) for the React Native source preview and its local conversion engine.

## Use Docenlume on macOS

1. Click the Docenlume menu bar icon or press **Control–Option–Command–E**.
2. Click **Add files**, drop files onto the widget, or paste files copied in Finder.
3. Hover over a format to preview it, then click to select it. Choose a **Save to** folder and click **Convert**.

Choose **Compress → Reduce file size** to save a smaller PDF, JPEG, or PNG with its original filename. **Create ZIP** bundles selected files of any type into one archive. Both compression modes accept files over 100 MB. If the output filename is already in use, Docenlume saves it in a new subfolder.

You can also select files in Finder and choose **Services → Convert with Docenlume**. If macOS blocks access to a file, use **Choose Files and Retry** to select it in the system picker.

Docenlume supports PDF, Word, plain text, and common image formats. See [supported conversions and limits](mac-utility/README.md#supported-routes-and-limits) for details. The [release checklist](RELEASING.md) covers packaging and publication.

## License

Docenlume's own source is available under the [GNU Affero General Public License, version 3](LICENSE). Third-party components keep their original licenses. See [third-party sources and notices](THIRD-PARTY.md).
