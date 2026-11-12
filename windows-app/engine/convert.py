"""Offline conversion entry point for the Windows desktop app."""
from __future__ import annotations

import argparse
from html import escape
from pathlib import Path
import os
import shutil
import subprocess
import sys
from collections.abc import Callable
from tempfile import TemporaryDirectory
from zipfile import ZIP_DEFLATED, ZipFile

import pymupdf
from PIL import Image, ImageOps
from docx import Document

# PyInstaller receives this same directory via --paths.
if not getattr(sys, "frozen", False):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "mac-utility" / "Engine"))
from pdf_editable import convert as layout_word, convert_flowing
from reduce_size import reduce_size

OUTPUTS = {"pdf", "docx", "jpg", "png", "tiff", "txt", "zip", "reduce-size"}
IMAGES = {"jpg", "jpeg", "png", "tif", "tiff", "gif", "webp", "bmp", "psd"}
OFFICE = {"doc", "docx", "odt", "rtf"}
TEXT = {"txt", "md", "csv", "json", "log", "xml", "yaml", "yml"}
ALIASES = {"jpeg": "jpg", "tif": "tiff"}
Image.MAX_IMAGE_PIXELS = 100_000_000


def read_text(path: Path) -> str:
    data = path.read_bytes()
    encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    try:
        return data.decode(encoding)
    except UnicodeError as error:
        raise ValueError("Save this text file as UTF-8 or UTF-16 and try again.") from error


def office_convert(source: Path, target: str, work: Path) -> Path:
    configured = os.environ.get("DOCENLUME_LIBREOFFICE") or os.environ.get("EASYCONVERT_LIBREOFFICE")
    candidates = [configured, shutil.which("soffice.com"), shutil.which("soffice")]
    for key in ("ProgramW6432", "ProgramFiles", "ProgramFiles(x86)"):
        if root := os.environ.get(key):
            candidates.append(str(Path(root) / "LibreOffice" / "program" / "soffice.com"))
    executable = next((path for path in candidates if path and Path(path).is_file()), None)
    if not executable:
        raise ValueError("Install LibreOffice to convert Word, RTF, or ODT files.")

    source_dir = work / "office-input"
    source_dir.mkdir()
    copied = source_dir / ("document" + source.suffix.lower())
    shutil.copyfile(source, copied)
    export = "txt:Text (encoded):UTF8" if target == "txt" else target
    command = [
        executable, f"-env:UserInstallation={(work / 'office-profile').as_uri()}",
        "--headless", "--convert-to", export, "--outdir", str(work), str(copied),
    ]
    try:
        subprocess.run(command, capture_output=True, check=True, timeout=120,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except subprocess.TimeoutExpired as error:
        raise ValueError("LibreOffice took too long to finish this conversion.") from error
    except subprocess.CalledProcessError as error:
        raise ValueError("LibreOffice couldn’t convert this document.") from error
    result = work / f"document.{target}"
    if not result.is_file() or result.stat().st_size == 0:
        raise ValueError("LibreOffice couldn’t convert this document.")
    return result


def write_text_document(text: str, target: str, path: Path) -> None:
    if target == "txt":
        path.write_text(text, encoding="utf-8")
    elif target == "docx":
        document = Document()
        for line in text.splitlines():
            document.add_paragraph(line)
        document.save(path)
    else:
        story = pymupdf.Story(
            '<div style="white-space: pre-wrap; overflow-wrap: anywhere">' +
            "<br>".join(escape(line) for line in text.split("\n")) + "</div>"
        )
        page = pymupdf.paper_rect("letter")
        content = page + (54, 54, -54, -54)
        writer = pymupdf.DocumentWriter(str(path))
        try:
            story.write(writer, lambda _number, _used: (page, content, None))
        finally:
            writer.close()


def flatten(image: Image.Image) -> Image.Image:
    if "A" not in image.getbands() and "transparency" not in image.info:
        return image.convert("RGB")
    rgba = image.convert("RGBA")
    background = Image.new("RGB", rgba.size, "white")
    background.paste(rgba, mask=rgba.getchannel("A"))
    return background


def save_image(image: Image.Image, path: Path, dpi: float | None = None) -> None:
    settings = {"dpi": (dpi, dpi)} if dpi else {}
    if path.suffix == ".jpg":
        image = flatten(image)
        settings.update(quality=94)
    elif image.mode not in {"RGB", "RGBA", "L", "LA", "P"}:
        image = image.convert("RGB")
    image.save(path, **settings)


def pdf_outputs(pdf: Path, target: str, mode: str, work: Path) -> list[Path]:
    result = work / f"output.{target}"
    with pymupdf.open(pdf) as document:
        if document.needs_pass:
            raise ValueError("This PDF requires a password. Save an unlocked copy and try again.")
        if not 1 <= len(document) <= 100:
            raise ValueError("Use a PDF with between 1 and 100 pages.")
        if target == "docx":
            (layout_word if mode == "layout" else convert_flowing)(str(pdf), str(result))
            return [result]
        if target == "txt":
            text = "\n".join(page.get_text() for page in document)
            if not text.strip():
                raise ValueError("No selectable text found. Scanned PDFs need OCR.")
            result.write_text(text, encoding="utf-8")
            return [result]
        pages = []
        for page in document:
            width, height = page.rect.width, page.rect.height
            scale = min(300 / 72, 8190 / max(width, height), (31_900_000 / (width * height)) ** 0.5)
            pixmap = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), colorspace=pymupdf.csRGB)
            image = Image.frombytes("RGB", (pixmap.width, pixmap.height), pixmap.samples)
            path = work / f"page-{page.number + 1:03d}.{target}"
            save_image(image, path, 72 * scale)
            pages.append(path)
        return pages


def render(source: Path, kind: str, target: str, mode: str, work: Path) -> list[Path]:
    output = work / f"output.{target}"
    if kind == "pdf":
        return pdf_outputs(source, target, mode, work)
    if kind in IMAGES:
        if target in {"docx", "txt"}:
            raise ValueError("Images can be converted to PDF, JPEG, PNG, or TIFF.")
        with Image.open(source) as original:
            if original.width * original.height > Image.MAX_IMAGE_PIXELS:
                raise ValueError("Images must be 100 megapixels or smaller.")
            image = ImageOps.exif_transpose(original)
            if target == "pdf":
                flatten(image).save(output)
            else:
                save_image(image, output)
        return [output]
    if kind in OFFICE:
        if target in {"pdf", "docx", "txt"}:
            return [office_convert(source, target, work)]
        return pdf_outputs(office_convert(source, "pdf", work), target, mode, work)
    text = read_text(source)
    if target in {"pdf", "docx", "txt"}:
        write_text_document(text, target, output)
        return [output]
    pdf = work / "text.pdf"
    write_text_document(text, "pdf", pdf)
    return pdf_outputs(pdf, target, mode, work)


def copy_new(source: Path, destination: Path) -> None:
    with source.open("rb") as input_file:
        output_file = destination.open("xb")
        try:
            with output_file:
                shutil.copyfileobj(input_file, output_file)
        except BaseException:
            destination.unlink(missing_ok=True)
            raise


def output_name(source: Path, target: str) -> str:
    if source.suffix.lower() == f".{target.lower()}":
        return source.name
    return f"{source.stem}.{target}"


def save_named(folder: Path, name: str, write: Callable[[Path], None]) -> Path:
    preferred = folder / name
    if not preferred.exists() and not preferred.is_symlink():
        try:
            write(preferred)
            return preferred
        except FileExistsError:
            pass
    for counter in range(1, 10_001):
        subfolder = folder / ("Docenlume" if counter == 1 else f"Docenlume {counter}")
        try:
            subfolder.mkdir()
        except FileExistsError:
            continue
        destination = subfolder / name
        try:
            write(destination)
            return destination
        except BaseException:
            try:
                subfolder.rmdir()
            except OSError:
                pass
            raise
    raise ValueError("Choose another save folder. Too many Docenlume folders already exist here.")


def save(outputs: list[Path], source: Path, folder: Path, target: str) -> Path:
    name = output_name(source, target)
    if len(outputs) == 1:
        return save_named(folder, name, lambda destination: copy_new(outputs[0], destination))

    def save_pages(destination: Path) -> None:
        destination.mkdir()
        written = []
        try:
            for index, page in enumerate(outputs, 1):
                page_folder = destination / f"Page {index:03d}"
                page_folder.mkdir()
                written.append(page_folder)
                copy_new(page, page_folder / name)
        except BaseException:
            for page_folder in written:
                (page_folder / name).unlink(missing_ok=True)
                page_folder.rmdir()
            destination.rmdir()
            raise

    return save_named(folder, source.stem, save_pages)


def convert(source: Path, folder: Path, target: str, mode: str) -> Path:
    if target == "zip":
        return compress([source], folder)
    source, folder = source.absolute(), folder.resolve()
    if not folder.is_dir():
        raise ValueError("Choose an available save folder.")
    if target == "reduce-size":
        if not source.is_file():
            raise ValueError("Choose a file to compress.")
        with TemporaryDirectory(prefix="docenlume-") as directory:
            candidate = Path(directory) / "compressed"
            reduce_size(source, candidate)
            return save_named(folder, source.name, lambda destination: copy_new(candidate, destination))
    kind = source.suffix[1:].lower()
    if not source.is_file() or kind not in IMAGES | OFFICE | TEXT | {"pdf"}:
        raise ValueError("Choose a supported document or image.")
    if source.stat().st_size > 100 * 1024 * 1024:
        raise ValueError("Files must be 100 MB or smaller.")
    if ALIASES.get(kind, kind) == target:
        raise ValueError(f"This file is already {target.upper()}. Pick another format.")
    with TemporaryDirectory(prefix="docenlume-") as directory:
        outputs = render(source, kind, target, mode, Path(directory))
        return save(outputs, source, folder, target)


def compress(sources: list[Path], folder: Path) -> Path:
    folder = folder.resolve()
    if not folder.is_dir():
        raise ValueError("Choose an available save folder.")
    name = output_name(sources[0], "zip") if len(sources) == 1 else "Archive.zip"
    with TemporaryDirectory(prefix="docenlume-") as directory:
        archive = Path(directory) / "output.zip"
        used = set()
        taken_names = {source.name.casefold() for source in sources}
        duplicate_count = 0
        with ZipFile(archive, "w", compression=ZIP_DEFLATED, strict_timestamps=False) as output:
            for source in sources:
                if not source.is_file():
                    raise ValueError(f"{source.name}: Choose a regular file to compress.")
                entry = source.name
                if entry.casefold() in used:
                    while True:
                        duplicate_count += 1
                        directory_name = "Docenlume" if duplicate_count == 1 else f"Docenlume {duplicate_count}"
                        if directory_name.casefold() not in taken_names:
                            break
                    entry = f"{directory_name}/{entry}"
                output.write(source, arcname=entry)
                used.add(source.name.casefold())
        return save_named(folder, name, lambda destination: copy_new(archive, destination))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("sources", type=Path, nargs="+")
    parser.add_argument("folder", type=Path)
    parser.add_argument("target", choices=sorted(OUTPUTS))
    parser.add_argument("mode", choices=("flowing", "layout"))
    parser.add_argument("result", type=Path)
    args = parser.parse_args()
    try:
        if args.target == "zip":
            result = compress(args.sources, args.folder)
        else:
            if len(args.sources) != 1:
                raise ValueError("Choose one source file per conversion.")
            result = convert(args.sources[0], args.folder, args.target, args.mode)
        response = "OK\n" + str(result)
    except PermissionError:
        response = "ERROR\nWindows blocked access to the file or save folder."
    except Exception as error:
        response = "ERROR\n" + (str(error) or "Conversion couldn’t finish.")
    args.result.write_text(response, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
