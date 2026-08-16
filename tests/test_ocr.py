import json
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from iphone_mirror_mcp.ctl import BINARY

ROOT = Path(__file__).resolve().parents[1]


def setup_module() -> None:
    subprocess.run([str(ROOT / "scripts" / "build-native.sh")], check=True)
    assert BINARY.is_file()


def _label_png(path: Path) -> None:
    image = Image.new("RGB", (400, 800), (0, 0, 0))
    draw = ImageDraw.Draw(image)
    font_path = Path("/System/Library/Fonts/Supplemental/Arial.ttf")
    if not font_path.is_file():
        font_path = Path("/System/Library/Fonts/Helvetica.ttc")
    font = ImageFont.truetype(str(font_path), 36)
    draw.text((24, 220), "Face ID & Passcode", fill=(255, 255, 255), font=font)
    image.save(path)


def test_ocr_finds_face_id_label(tmp_path: Path) -> None:
    png = tmp_path / "face-id.png"
    _label_png(png)
    proc = subprocess.run(
        [
            str(BINARY),
            "ocr",
            "--image",
            str(png),
            "--query",
            "Face ID",
            "--limit",
            "4",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    payload = json.loads(proc.stdout.strip().splitlines()[-1])
    assert payload["ok"] is True
    assert payload["found"] is True
    assert "Face ID" in payload["text"]
    assert 0.2 < payload["cy"] < 0.45
    assert 0.2 < payload["cx"] < 0.8


def test_ocr_miss_is_found_false(tmp_path: Path) -> None:
    png = tmp_path / "empty.png"
    Image.new("RGB", (200, 200), (0, 0, 0)).save(png)
    proc = subprocess.run(
        [str(BINARY), "ocr", "--image", str(png), "--query", "Subscribe"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    payload = json.loads(proc.stdout.strip().splitlines()[-1])
    assert payload["found"] is False
    assert payload["n"] == 0
