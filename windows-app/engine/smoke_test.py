"""Exercise the same command and result protocol the Windows host uses."""
from pathlib import Path
import random
import subprocess
import sys
from tempfile import TemporaryDirectory
from zipfile import ZipFile

from docx import Document
from PIL import Image
import pymupdf


def check(command: list[str]) -> None:
    with TemporaryDirectory(prefix="QuickConvrt smoke ") as temporary:
        root = Path(temporary).resolve()
        folder = root / "Save folder"
        folder.mkdir()
        response = root / "result.txt"
        source = root / "Project notes.v2.txt"
        contents = "Quarterly review.\nMeeting notes from Québec."
        source.write_text(contents, encoding="utf-8")

        def convert(path: Path | list[Path], target: str, mode: str = "flowing", save_to: Path = folder) -> Path:
            sources = path if isinstance(path, list) else [path]
            subprocess.run([*command, *map(str, sources), str(save_to), target, mode, str(response)], check=True)
            status, result = response.read_text(encoding="utf-8").split("\n", 1)
            assert status == "OK", result
            return Path(result)

        pdf = convert(source, "pdf")
        assert pdf == folder / "Project notes.v2.pdf"
        with pymupdf.open(pdf) as document:
            assert len(document) == 1
            assert "Québec" in document[0].get_text()
        word = convert(pdf, "docx")
        assert word.name == "Project notes.v2.docx"
        assert "Québec" in " ".join(p.text for p in Document(word).paragraphs)
        assert convert(source, "pdf") == folder / "QuickConvrt" / pdf.name
        assert source.read_text(encoding="utf-8") == contents
        with Image.open(convert(pdf, "png")) as image:
            assert image.format == "PNG"
        multi = root / "Slides.pdf"
        with pymupdf.open() as document:
            for _ in range(2):
                document.new_page(width=120, height=80)
            document.save(multi)
        pages = convert(multi, "jpg")
        assert pages == folder / "Slides"
        assert {item.relative_to(pages).as_posix() for item in pages.rglob("*.jpg")} == {"Page 001/Slides.jpg", "Page 002/Slides.jpg"}

        duplicate_dir = root / "Other files"
        duplicate_dir.mkdir()
        duplicate = duplicate_dir / source.name
        duplicate.write_text("Different contents", encoding="utf-8")
        extra = root / "[sample].bin"
        extra.write_bytes(b"example" * 1_000)
        assert convert(extra, "zip").name == "[sample].zip"
        archive = convert([source, duplicate, extra], "zip")
        assert archive.name == "Archive.zip"
        with ZipFile(archive) as zipped:
            assert zipped.read(source.name) == source.read_bytes()
            assert zipped.read("QuickConvrt/Project notes.v2.txt") == duplicate.read_bytes()
            assert zipped.read(extra.name) == extra.read_bytes()
        assert convert([source, duplicate], "zip") == folder / "QuickConvrt 2" / archive.name

        large_file = root / "Large sample.bin"
        with large_file.open("wb") as sample:
            sample.seek(110 * 1024 * 1024)
            sample.write(b"end")
        large_zip = convert(large_file, "zip")
        assert large_zip.stat().st_size < 1024 * 1024
        with ZipFile(large_zip) as zipped:
            assert zipped.getinfo(large_file.name).file_size == large_file.stat().st_size
            assert zipped.testzip() is None
            with zipped.open(large_file.name) as restored:
                restored.seek(-3, 2)
                assert restored.read() == b"end"

        picture = root / "Photo.v2.PNG"
        with Image.new("RGBA", (320, 240), (15, 90, 150, 100)) as original:
            original.save(picture, compress_level=0)
            reduced = convert(picture, "reduce-size")
            assert reduced == folder / picture.name
            assert reduced.stat().st_size < picture.stat().st_size
            with Image.open(reduced) as saved:
                assert saved.format == "PNG" and saved.tobytes() == original.tobytes()
        assert convert(picture, "reduce-size") == folder / "QuickConvrt 3" / picture.name
        assert convert(picture, "reduce-size", save_to=root) == root / "QuickConvrt" / picture.name
        before = set(folder.iterdir())
        subprocess.run([*command, str(reduced), str(folder), "reduce-size", "flowing", str(response)], check=True)
        assert response.read_text(encoding="utf-8").startswith("ERROR\nThis file is already compact.")
        assert set(folder.iterdir()) == before

        large_picture = root / "Large picture.png"
        with Image.new("RGBA", (5200, 5200), (15, 90, 150, 100)) as original:
            original.save(large_picture, compress_level=0)
        assert large_picture.stat().st_size > 100 * 1024 * 1024
        large_reduced = convert(large_picture, "reduce-size")
        assert large_reduced.stat().st_size < large_picture.stat().st_size
        with Image.open(large_reduced) as saved:
            assert saved.format == "PNG" and saved.size == (5200, 5200)
            assert saved.getpixel((5199, 5199)) == (15, 90, 150, 100)

        photo = root / "Scan.jpg"
        with Image.frombytes("RGB", (512, 512), random.Random(0).randbytes(512 * 512 * 3)) as noise:
            noise.save(photo, quality=98)
        with Image.open(convert(photo, "reduce-size")) as smaller:
            assert smaller.format == "JPEG" and smaller.size == (512, 512)
        scanned = root / "Scan with notes.pdf"
        with pymupdf.open() as document:
            page = document.new_page(width=200, height=240)
            page.insert_image(pymupdf.Rect(20, 20, 165, 165), filename=photo)
            page.insert_text((20, 200), "Searchable caption")
            for _ in range(99):
                document.new_page(width=200, height=240)
            document.new_page(width=200, height=240).insert_text((20, 60), "Final page")
            document.ez_save(scanned)
        smaller_pdf = convert(scanned, "reduce-size")
        assert smaller_pdf.stat().st_size < scanned.stat().st_size
        with pymupdf.open(smaller_pdf) as saved:
            assert len(saved) == 101
            assert saved[0].get_text().strip() == "Searchable caption"
            assert saved[-1].get_text().strip() == "Final page"


if __name__ == "__main__":
    check(sys.argv[1:])
    print("Offline conversion smoke checks passed.")
