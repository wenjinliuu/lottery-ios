"""Make a self-contained, editable HTML file from the recorded simulator frames."""
import argparse
import base64
import mimetypes
from pathlib import Path
import re


def embedded(path):
    media_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    data = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:{media_type};base64,{data}"


def package(destination):
    studio = Path(__file__).resolve().parent
    snapshots = studio.parents[1] / "Tests/LotteryWalletUITests/__Snapshots__"
    template = (studio / "index.html").read_text()
    pattern = r"(['\"])((?:KeyFlowTests|AppStoreScreenshotTests|art)/[^'\"]+\.png)\1"

    def embed_snapshot(match):
        return '"' + embedded((studio if match[2].startswith("art/") else snapshots) / match[2]) + '"'

    page, count = re.subn(pattern, embed_snapshot, template)
    if count != 5:
        raise ValueError(f"Expected five store screenshots, found {count}")
    page = re.sub(r"const base\s*=\s*['\"][^'\"]*['\"]", 'const base = ""', page)
    page = page.replace("vendor/html2canvas.min.js", embedded(studio / "vendor/html2canvas.min.js"))
    page = page.replace('src="app-icon.png"', 'src="' + embedded(studio / "app-icon.png") + '"')
    license_text = (studio / "vendor/LICENSE").read_text()
    page = page.replace("</html>", f"<!-- html2canvas license\n{license_text}\n-->\n</html>")
    destination.write_text(page)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    package(parser.parse_args().destination)
