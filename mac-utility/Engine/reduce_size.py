"""Make a smaller copy without changing the file format."""
from pathlib import Path
from tempfile import TemporaryDirectory

import pymupdf
from PIL import Image, PngImagePlugin

SUPPORTED_EXTENSIONS = {".pdf", ".jpg", ".jpeg", ".png"}


def reduce_pdf(source: Path, destination: Path, original_size: int) -> None:
    with pymupdf.open(source) as pdf:
        if pdf.needs_pass or (pdf.metadata or {}).get("encryption"):
            raise ValueError("Use an unlocked copy to compress this PDF.")
        if pdf.get_sigflags() > 1:
            raise ValueError("Use Create ZIP to preserve this PDF’s digital signature.")
        if len(pdf) == 0:
            raise ValueError("This PDF has no pages to compress.")

        pdf.ez_save(destination)
        # Keep a useful lossless result. Recompress images when lossless
        # optimization makes little difference.
        if destination.stat().st_size <= original_size * 0.85:
            return
        if not any(page.get_images() for page in pdf):
            return
        with TemporaryDirectory(prefix="quickconvrt-pdf-", dir=destination.parent) as directory:
            candidate = Path(directory) / "images.pdf"
            pdf.rewrite_images(dpi_threshold=200, dpi_target=150, quality=80, bitonal=False)
            pdf.ez_save(candidate)
            if candidate.stat().st_size < destination.stat().st_size:
                candidate.replace(destination)


def reduce_image(source: Path, destination: Path) -> None:
    with Image.open(source) as image:
        if image.width * image.height > 100_000_000:
            raise ValueError("Images must be 100 megapixels or smaller.")
        if getattr(image, "n_frames", 1) != 1 or image.format not in {"JPEG", "PNG"}:
            raise ValueError("Use Create ZIP to preserve this image’s format and frames.")

        image.load()
        metadata = {key: image.info[key] for key in ("icc_profile", "exif", "dpi") if key in image.info}
        if image.format == "JPEG":
            image.save(destination, "JPEG", quality=78, optimize=True, **metadata)
            return

        # Pillow opens 16-bit color PNGs as 8-bit images. Keep the original
        # bit depth by refusing that conversion.
        with source.open("rb") as file:
            if file.read(25)[24:25] == b"\x10":
                raise ValueError("Use Create ZIP to preserve this PNG’s 16-bit color.")
        pnginfo = PngImagePlugin.PngInfo()
        for key, value in image.text.items():
            if isinstance(value, PngImagePlugin.iTXt):
                pnginfo.add_itxt(key, value, value.lang, value.tkey)
            else:
                pnginfo.add_text(key, value)
        if "transparency" in image.info:
            metadata["transparency"] = image.info["transparency"]
        for key, chunk, scale in (("gamma", b"gAMA", 100000), ("srgb", b"sRGB", 1)):
            if key in image.info:
                pnginfo.add(chunk, round(image.info[key] * scale).to_bytes(4 if key == "gamma" else 1, "big"))
        image.save(destination, "PNG", optimize=True, pnginfo=pnginfo, **metadata)


def reduce_size(source: Path, destination: Path) -> None:
    """Write to a temporary destination. Only return success for a smaller file."""
    extension = source.suffix.lower()
    if extension not in SUPPORTED_EXTENSIONS:
        raise ValueError("Reduce file size supports PDF, JPEG, and PNG. Use Create ZIP for other files.")
    original_size = source.stat().st_size
    if extension == ".pdf":
        reduce_pdf(source, destination, original_size)
    else:
        reduce_image(source, destination)
    if destination.stat().st_size >= original_size:
        destination.unlink()
        raise ValueError("This file is already compact. No smaller copy was saved.")
