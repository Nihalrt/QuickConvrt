# Release Docenlume for Mac

Offer the Mac app ZIP as a free download under **Assets** on [Docenlume Releases](https://github.com/Nihalrt/Docenlume/releases). Publish the exact source and build scripts under AGPL-3.0 and provide the corresponding source for bundled components. See [third-party sources and notices](THIRD-PARTY.md). Keep the app bundle, private test documents, and generated conversions outside Git history.

Build in a fresh checkout of the release source on an Apple Silicon Mac with Xcode Command Line Tools, Python 3.12.14, and a verified copy of the official Apple Silicon LibreOffice 26.8.2.2 app. Use a clean virtual environment and resolve wheels for macOS 13. Installing directly on a newer host may select a NumPy wheel that requires macOS 14.

```sh
cd mac-utility
python3.12 -m venv build/pdf-engine-env
build/pdf-engine-env/bin/python -m pip download --only-binary=:all: \
  --platform macosx_13_0_arm64 --python-version 3.12 --dest build/wheelhouse \
  -r Engine/requirements-mac-release.txt
build/pdf-engine-env/bin/python -m pip install --no-index --find-links build/wheelhouse \
  -r Engine/requirements-mac-release.txt
./stage-office-engine.sh /path/to/LibreOffice.app
```

Install a [Developer ID Application identity](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) on the build Mac and configure a `notarytool` Keychain profile. Set `DOCENLUME_CODESIGN_IDENTITY` to the name or fingerprint shown by `security find-identity -v -p codesigning`. The build signs the PDF helper and app with Developer ID and verifies the staged LibreOffice signature. The development build uses ad hoc signing when the identity is unset.

```sh
export DOCENLUME_CODESIGN_IDENTITY='Developer ID Application: Name (TEAMID)'
./build-engine.sh
./build.sh
build/Docenlume.app/Contents/MacOS/Docenlume --self-test
build/pdf-engine-env/bin/python -m unittest discover -s Engine
```

Submit a ZIP containing the signed app. After Apple accepts it, staple the ticket to the app, validate it, and create the final ZIP. See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

```sh
cd build
ditto -c -k --sequesterRsrc --keepParent Docenlume.app Docenlume-notarization.zip
xcrun notarytool submit Docenlume-notarization.zip --keychain-profile docenlume-notary --wait
xcrun stapler staple Docenlume.app
xcrun stapler validate Docenlume.app
spctl --assess --type execute --verbose Docenlume.app
ditto -c -k --sequesterRsrc --keepParent Docenlume.app Docenlume-Mac-arm64-v0.4.13.zip
shasum -a 256 Docenlume-Mac-arm64-v0.4.13.zip > Docenlume-Mac-arm64-v0.4.13.zip.sha256
```

Test first launch, Finder Services, and a conversion using each engine from the final ZIP on a clean Apple Silicon Mac. Draft `v0.4.13` against the tested commit, attach the app ZIP, checksum, and corresponding source assets, and copy the [Mac install steps](README.md#install-on-macos) into the release notes. Publish and check the asset link from a signed-out browser. See [GitHub's release instructions](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository).
