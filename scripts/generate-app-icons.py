#!/usr/bin/env python3
"""Décline le SVG en icônes iOS et Android (macOS, Quick Look, ffmpeg, sips)."""

import json
import argparse
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "design/app-icon/parcourses-ocre-encre.svg"
RES = ROOT / "android/app/src/main/res"
NS = "{http://www.w3.org/2000/svg}"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True, stdout=subprocess.DEVNULL)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text + "\n")


def generate(rendered=None):
    with tempfile.TemporaryDirectory(prefix="parcourses-icons-", dir="/private/tmp") as temp:
        temp = Path(temp)
        if rendered is None:
            run("qlmanage", "-t", "-s", "1024", "-o", temp, SOURCE)
            rendered = temp / (SOURCE.name + ".png")
        # RGB24 garantit un PNG iOS sans canal alpha.
        run("ffmpeg", "-loglevel", "error", "-y", "-i", rendered,
            "-frames:v", "1", "-pix_fmt", "rgb24", temp / "master.png")
        catalog = ROOT / "ios/Parcourses/Assets.xcassets"
        icon = catalog / "AppIcon.appiconset"
        write(catalog / "Contents.json", json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))
        icon.mkdir(parents=True, exist_ok=True)
        run("sips", "-z", "1024", "1024", temp / "master.png", "--out", icon / "AppIcon.png")
        write(icon / "Contents.json", json.dumps({
            "images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
            "info": {"author": "xcode", "version": 1},
        }, indent=2))
        for density, size in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
            target = RES / ("mipmap-" + density) / "ic_launcher.png"
            target.parent.mkdir(parents=True, exist_ok=True)
            run("sips", "-z", size, size, temp / "master.png", "--out", target)

    svg = ET.parse(SOURCE).getroot()
    # Le dessin est réduit dans le calque de 108 dp pour les masques adaptatifs.
    # Ses contours tiennent dans le cercle central sûr de 66 dp.
    groups = []
    for group in svg.findall(NS + "g"):
        paths = "\n".join(
            f'      <path android:fillColor="{group.attrib["fill"]}" android:pathData="{path.attrib["d"]}" />'
            for path in group.findall(NS + "path")
        )
        groups.append('    <group android:translateY="1254" android:scaleX="0.1" android:scaleY="-0.1">\n' + paths + '\n    </group>')
    write(RES / "drawable/ic_launcher_foreground.xml",
          '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
          '    android:width="108dp" android:height="108dp" android:viewportWidth="1254" android:viewportHeight="1254">\n'
          '  <group android:pivotX="627" android:pivotY="627" android:scaleX="0.72" android:scaleY="0.72">\n'
          + "\n".join(groups) + '\n  </group>\n</vector>')
    # Masque monochrome Android 13 : panier et arrivée forment le même symbole.
    foreground = (RES / "drawable/ic_launcher_foreground.xml").read_text()
    for color in ("#202A43", "#FFF7E8"):
        foreground = foreground.replace(color, "#FFFFFFFF")
    write(RES / "drawable/ic_launcher_monochrome.xml", foreground.rstrip())
    background = svg.find(NS + "rect").attrib["fill"]
    write(RES / "values/ic_launcher_colors.xml", f'<resources>\n    <color name="ic_launcher_background">{background}</color>\n</resources>')
    for name in ("ic_launcher", "ic_launcher_round"):
        for version in (26, 33):
            monochrome = '\n    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />' if version == 33 else ""
            write(RES / f"mipmap-anydpi-v{version}/{name}.xml",
                  '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                  '    <background android:drawable="@color/ic_launcher_background" />\n'
                  '    <foreground android:drawable="@drawable/ic_launcher_foreground" />'
                  + monochrome + '\n</adaptive-icon>')


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rendered", type=Path, help="PNG 1024 du SVG déjà rendu avec Quick Look")
    generate(parser.parse_args().rendered)
