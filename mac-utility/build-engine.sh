#!/bin/zsh
set -eu
cd "$(dirname "$0")"
test -x build/pdf-engine-env/bin/python || { print 'Create build/pdf-engine-env and install Engine/requirements.txt first.'; exit 1; }
export PYINSTALLER_CONFIG_DIR="$PWD/build/pyinstaller-cache"
signing=()
if [[ -n "${DOCENLUME_CODESIGN_IDENTITY:-}" ]]; then
    signing=(--codesign-identity "$DOCENLUME_CODESIGN_IDENTITY")
fi
build/pdf-engine-env/bin/python -m PyInstaller --noconfirm --onedir --name pdf-editable --distpath build/frozen --workpath build/freeze-work --specpath build --exclude-module matplotlib --exclude-module pandas --exclude-module onnxruntime --exclude-module scipy --collect-data fontTools --collect-data pymupdf --collect-data docx "${signing[@]}" Engine/pdf_editable.py
build/pdf-engine-env/bin/python Engine/stage_notices.py build/frozen/pdf-editable/licenses
