param([string]$Python = "python")
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Push-Location $PSScriptRoot
try {
    & $Python -c "import struct, sys; sys.exit(0 if sys.version_info[:2] == (3, 12) and struct.calcsize('P') == 8 else 'Use Python 3.12 x64 to build the conversion engine.')"
    & $Python -m venv build/.venv
    $VenvPython = Join-Path $PWD "build/.venv/Scripts/python.exe"
    & $VenvPython -m pip install --disable-pip-version-check -r ../mac-utility/Engine/requirements.txt
    & $VenvPython -m unittest discover -s ../mac-utility/Engine
    & $VenvPython -m PyInstaller --noconfirm --clean --onedir --noupx --name quickconvrt-engine `
        --paths ../mac-utility/Engine --distpath build/engine --workpath build/pyinstaller `
        --collect-data fontTools --collect-data pymupdf --collect-data docx `
        --exclude-module matplotlib --exclude-module pandas --exclude-module onnxruntime --exclude-module scipy `
        --specpath build (Resolve-Path engine/convert.py)
    & $VenvPython engine/smoke_test.py (Resolve-Path build/engine/quickconvrt-engine/quickconvrt-engine.exe)
} finally {
    Pop-Location
}
