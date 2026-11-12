# Third-party sources and notices

Docenlume uses PyMuPDF and MuPDF under AGPL-3.0. The Mac build also bundles the original LibreOffice renderer and a frozen Python runtime. The build copies the installed Python packages' notices into `Contents/Resources/PDFEngine/licenses/` and retains LibreOffice's notices inside its bundle. React Native Windows template code carries its [original MIT notice](windows-app/THIRD-PARTY-TEMPLATE-LICENSE.txt).

| Component | Source used for the Docenlume Mac build |
| --- | --- |
| Docenlume | This repository. The release tag identifies the source and build scripts for the installer. |
| PyMuPDF 1.28.2 | [Source distribution on PyPI](https://pypi.org/project/PyMuPDF/1.28.2/#files). Choose `pymupdf-1.28.2.tar.gz`. |
| MuPDF 1.28.2 | [Upstream source archive](https://mupdf.com/downloads/archive/mupdf-1.28.2-source.tar.gz), as referenced by the PyMuPDF build. |
| LibreOffice 26.8.2.2 | [The Document Foundation downloads](https://us.libreoffice.org/download/libreoffice-stable/?lang=en-US&type=mac-aarch64&version=26.8.2), including the versioned source archives. |
| Python 3.12.14 | [CPython source](https://github.com/python/cpython/tree/v3.12.14). |
| PDF helper dependencies | [Direct dependencies](mac-utility/Engine/requirements.txt) and [resolved Mac build dependencies](mac-utility/Engine/requirements-mac-release.txt). |
