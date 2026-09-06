#!/usr/bin/env python3
# SPDX-License-Identifier: OFL-1.1
"""Build the renamed display-font subset from pinned upstream font data."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import tempfile
import unicodedata
from urllib.request import urlopen

import fontTools
from fontTools import subset
from fontTools.ttLib import TTFont


ROOT = Path(__file__).resolve().parents[1]
TAG = "Serif2.003"
BASE = f"https://raw.githubusercontent.com/notofonts/noto-cjk/{TAG}/Serif/"
FONT_URL = BASE + "OTF/SimplifiedChinese/NotoSerifCJKsc-ExtraLight.otf"
LICENSE_URL = BASE + "LICENSE"
FONT_SHA256 = "12270613d011f70c0e1875affc845ba272e0ce1d78ca9a4398dc34cc67984b62"
LICENSE_SHA256 = "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2"
POSTSCRIPT_NAME = "WSJDisplay-ExtraLight"
FAMILY_NAME = "WSJ Display"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def checked_data(path, url, expected):
    if path:
        data = path.read_bytes()
    else:
        with urlopen(url, timeout=90) as response:
            data = response.read()
    if digest(data) != expected:
        raise ValueError(f"Unexpected SHA256 for {url}")
    return data


def source_characters():
    points = set(range(0x20, 0x7F))
    files = sorted((ROOT / "App").rglob("*.swift"))
    for path in files:
        text = path.read_text(encoding="utf-8")
        points.update(ord(char) for char in text if unicodedata.category(char)[0] != "C")
        for match in re.finditer(r"\\u\{([0-9a-fA-F]+)\}", text):
            point = int(match.group(1), 16)
            if unicodedata.category(chr(point))[0] != "C":
                points.add(point)
    return sorted(points), files


def rename_font(font):
    names = {
        1: FAMILY_NAME, 2: "ExtraLight", 3: "WSJDisplay-ExtraLight;2.003;subset-v1",
        4: "WSJ Display ExtraLight", 5: "Version 2.003; WSJ app subset 1",
        6: POSTSCRIPT_NAME, 16: FAMILY_NAME, 17: "ExtraLight",
        18: "WSJ Display ExtraLight", 20: POSTSCRIPT_NAME,
        21: FAMILY_NAME, 22: "ExtraLight", 25: "WSJDisplay",
    }
    table = font["name"]
    for record in list(table.names):
        if record.nameID in names:
            table.setName(names[record.nameID], record.nameID,
                          record.platformID, record.platEncID, record.langID)
    for name_id in (1, 2, 3, 4, 5, 6, 16, 17):
        table.setName(names[name_id], name_id, 3, 1, 0x409)
    cff = font["CFF "].cff
    cff.fontNames = [POSTSCRIPT_NAME]
    top = cff.topDictIndex[0]
    top.FullName = "WSJ Display ExtraLight"
    top.FamilyName = FAMILY_NAME
    if hasattr(top, "FontName"):
        top.FontName = POSTSCRIPT_NAME
    for index, entry in enumerate(getattr(top, "FDArray", [])):
        if hasattr(entry, "FontName"):
            entry.FontName = f"{POSTSCRIPT_NAME}-FD{index}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-font", type=Path)
    parser.add_argument("--source-license", type=Path)
    args = parser.parse_args()
    if fontTools.__version__ != "4.60.0":
        raise RuntimeError("Use fonttools==4.60.0 for a reproducible subset")
    font_data = checked_data(args.source_font, FONT_URL, FONT_SHA256)
    license_data = checked_data(args.source_license, LICENSE_URL, LICENSE_SHA256)
    points, files = source_characters()
    target = ROOT / "App" / "Resources" / "Fonts"
    target.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="wsj-font-") as temporary:
        source = Path(temporary) / "source.otf"
        source.write_bytes(font_data)
        font = TTFont(source, recalcTimestamp=False)
        missing = sorted(set(points) - set(font.getBestCmap()))
        if missing:
            raise ValueError("Upstream lacks source characters: " + ", ".join(f"U+{p:04X}" for p in missing))
        copyright_notice = font["name"].getDebugName(0)
        options = subset.Options()
        options.name_IDs = ["*"]
        options.name_languages = ["*"]
        options.name_legacy = True
        options.layout_features = ["*"]
        options.notdef_glyph = True
        options.notdef_outline = True
        options.recommended_glyphs = True
        options.recalc_timestamp = False
        subsetter = subset.Subsetter(options=options)
        subsetter.populate(unicodes=points)
        subsetter.subset(font)
        rename_font(font)
        output = target / f"{POSTSCRIPT_NAME}.otf"
        font.save(output, reorderTables=True)
        font.close()
    with TTFont(output, recalcTimestamp=False) as result:
        assert result["name"].getDebugName(6) == POSTSCRIPT_NAME
        assert result["CFF "].cff.fontNames == [POSTSCRIPT_NAME]
        assert set(points).issubset(result.getBestCmap())
        assert result["name"].getDebugName(0) == copyright_notice
        glyph_count = result["maxp"].numGlyphs
    (target / "OFL.txt").write_bytes(license_data)
    (target / "COPYRIGHT.txt").write_text(copyright_notice + "\n", encoding="utf-8")
    (target / "codepoints.txt").write_text("\n".join(f"U+{point:04X}" for point in points) + "\n", encoding="utf-8")
    report = {
        "upstream_tag": TAG, "font_url": FONT_URL, "license_url": LICENSE_URL,
        "source_font_sha256": FONT_SHA256, "license_sha256": LICENSE_SHA256,
        "fonttools_version": fontTools.__version__, "postscript_name": POSTSCRIPT_NAME,
        "source_file_count": len(files), "codepoint_count": len(points), "glyph_count": glyph_count,
        "subset_bytes": output.stat().st_size, "subset_sha256": digest(output.read_bytes()),
        "codepoints_sha256": digest((target / "codepoints.txt").read_bytes()),
    }
    (target / "subset-manifest.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
