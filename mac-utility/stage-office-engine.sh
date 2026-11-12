#!/bin/zsh
set -eu
cd "$(dirname "$0")"
SOURCE="${1:?Usage: ./stage-office-engine.sh /absolute/path/LibreOffice.app}"
test -x "$SOURCE/Contents/MacOS/soffice" || { print 'Choose a complete LibreOffice application bundle.'; exit 1; }
test -f "$SOURCE/Contents/Resources/LICENSE" || { print 'The renderer license is missing.'; exit 1; }
mkdir -p build/office-engine
/usr/bin/ditto "$SOURCE" "$PWD/build/office-engine/LibreOfficeDev.app"
print 'Document renderer staged. Run ./build.sh next.'
