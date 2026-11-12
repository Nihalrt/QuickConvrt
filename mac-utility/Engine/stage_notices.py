"""Copy notices for the versions used to build the PDF engine."""

from importlib.metadata import distribution
from pathlib import Path
from shutil import copyfile
import sys
import sysconfig


PDF_ENGINE_PACKAGES = (
    "fire", "fonttools", "lxml", "numpy", "opencv-python-headless", "pdf2docx",
    "Pillow", "PyInstaller", "PyMuPDF", "python-docx", "termcolor", "typing-extensions",
)


def stage_notices(destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    copyfile(Path(sysconfig.get_path("stdlib")) / "LICENSE.txt", destination / "Python-LICENSE.txt")
    for name in PDF_ENGINE_PACKAGES:
        package = distribution(name)
        notice_files = [
            path for path in package.files or ()
            if "licenses" in path.parts or path.name.lower().startswith(("license", "copying", "notice"))
        ]
        if not notice_files:
            raise RuntimeError(f"No license files found for {name} {package.version}")
        for path in notice_files:
            if path.is_absolute() or ".." in path.parts:
                raise RuntimeError(f"Unexpected license path for {name}: {path}")
            output = destination / f"{name}-{package.version}" / path
            output.parent.mkdir(parents=True, exist_ok=True)
            copyfile(package.locate_file(path), output)


if __name__ == "__main__":
    stage_notices(Path(sys.argv[1]))
