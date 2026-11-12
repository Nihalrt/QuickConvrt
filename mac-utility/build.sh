#!/bin/zsh
set -eu
cd "$(dirname "$0")"
APP="$PWD/build/Docenlume.app"
mkdir -p "$APP/Contents/MacOS" "$PWD/build/module-cache"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
glass_header="System/Library/Frameworks/AppKit.framework/Headers/NSGlassEffectView.h"
clt="/Library/Developer/CommandLineTools"
compiler=(xcrun swiftc)
features=()
if [[ ! -f "$sdk/$glass_header" && -f "$clt/SDKs/MacOSX.sdk/$glass_header" && -x "$clt/usr/bin/swiftc" ]]; then
    sdk="$clt/SDKs/MacOSX.sdk"
    compiler=("$clt/usr/bin/swiftc")
fi
if [[ -f "$sdk/$glass_header" ]]; then features=(-D DOCENLUME_NATIVE_GLASS); fi
"${compiler[@]}" -sdk "$sdk" "${features[@]}" -swift-version 5 -O -target "$(uname -m)-apple-macos13.0" -module-cache-path "$PWD/build/module-cache" -framework AppKit -framework PDFKit -framework CoreText -framework ImageIO -framework Carbon -framework Security Sources/*.swift -o "$APP/Contents/MacOS/Docenlume"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
iconset="$PWD/build/Docenlume.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" Assets/Docenlume.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    /usr/bin/sips -z "$retina" "$retina" Assets/Docenlume.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$APP/Contents/Resources/Docenlume.icns"
test -d "$PWD/build/office-engine/LibreOfficeDev.app" || { print 'Stage the LibreOffice renderer in build/office-engine/LibreOfficeDev.app first.'; exit 1; }
/usr/bin/ditto "$PWD/build/office-engine" "$APP/Contents/Resources/OfficeEngine"
test -x "$PWD/build/frozen/pdf-editable/pdf-editable" || { print 'Build the local PDF engine with ./build-engine.sh first.'; exit 1; }
/usr/bin/ditto "$PWD/build/frozen/pdf-editable" "$APP/Contents/Resources/PDFEngine"
mkdir -p "$APP/Contents/Resources/PDFEngine/source"
cp Engine/pdf_editable.py Engine/flowing_word.py Engine/reduce_size.py "$APP/Contents/Resources/PDFEngine/source/"
cp ../LICENSE "$APP/Contents/Resources/LICENSE"
if [[ -n "${DOCENLUME_CODESIGN_IDENTITY:-}" ]]; then
    /usr/bin/codesign --verify --deep --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' \
        "$APP/Contents/Resources/OfficeEngine/LibreOfficeDev.app"
    /usr/bin/codesign --verify --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' \
        "$APP/Contents/Resources/PDFEngine/pdf-editable"
    /usr/bin/codesign --force --sign "$DOCENLUME_CODESIGN_IDENTITY" --options runtime --timestamp "$APP"
else
    /usr/bin/codesign --force --sign - "$APP"
fi
/usr/bin/codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
