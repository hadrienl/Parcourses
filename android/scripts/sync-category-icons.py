#!/usr/bin/env python3
"""Convertit les icônes de rayon (design/icons/categories/*.svg) en vector drawables de :core:designsystem.

Les SVG restent la source de vérité (PR #23) : grille 24, trait de 1,5, extrémités et jonctions arrondies. Le trait
est noir dans le drawable et prend la couleur du rayon par la teinte (`Icon(tint = ...)`).

Sous-ensemble pris en charge, celui du jeu validé : `path`, `circle` et `rect` (coins arrondis, rotation). Tout autre
élément fait échouer la conversion, pour qu'une nouvelle icône ne soit jamais tronquée en silence.

Usage : sync-category-icons.py [--check]. Avec --check, n'écrit rien et échoue si un drawable diffère (CI).
"""

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "design" / "icons" / "categories"
DST = ROOT / "android" / "core" / "designsystem" / "src" / "main" / "res" / "drawable"
SVG = "{http://www.w3.org/2000/svg}"
INK = "#FF000000"


def num(value: str) -> str:
    """Nombre SVG réécrit sans zéro inutile (« .8 » devient « 0.8 »)."""
    text = f"{float(value):.4f}".rstrip("0").rstrip(".")
    return text if text not in ("-0", "") else "0"


def circle_path(el: ET.Element) -> str:
    cx, cy, r = (float(el.get(k)) for k in ("cx", "cy", "r"))
    return (
        f"M{num(cx - r)},{num(cy)}"
        f"a{num(r)},{num(r)} 0 1,0 {num(2 * r)},0"
        f"a{num(r)},{num(r)} 0 1,0 {num(-2 * r)},0Z"
    )


def rect_path(el: ET.Element) -> str:
    x, y, w, h = (float(el.get(k)) for k in ("x", "y", "width", "height"))
    rx = float(el.get("rx", el.get("ry", "0")))
    ry = float(el.get("ry", el.get("rx", "0")))
    rx, ry = min(rx, w / 2), min(ry, h / 2)
    if rx == 0 or ry == 0:
        return f"M{num(x)},{num(y)}h{num(w)}v{num(h)}h{num(-w)}Z"
    return (
        f"M{num(x + rx)},{num(y)}"
        f"h{num(w - 2 * rx)}a{num(rx)},{num(ry)} 0 0,1 {num(rx)},{num(ry)}"
        f"v{num(h - 2 * ry)}a{num(rx)},{num(ry)} 0 0,1 {num(-rx)},{num(ry)}"
        f"h{num(-(w - 2 * rx))}a{num(rx)},{num(ry)} 0 0,1 {num(-rx)},{num(-ry)}"
        f"v{num(-(h - 2 * ry))}a{num(rx)},{num(ry)} 0 0,1 {num(rx)},{num(-ry)}Z"
    )


def path_xml(data: str, filled: bool, indent: str) -> str:
    fill = f'\n{indent}    android:fillColor="{INK}"' if filled else ""
    stroke = (
        ""
        if filled
        else (
            f'\n{indent}    android:strokeColor="{INK}"'
            f'\n{indent}    android:strokeWidth="1.5"'
            f'\n{indent}    android:strokeLineCap="round"'
            f'\n{indent}    android:strokeLineJoin="round"'
        )
    )
    return f'{indent}<path{fill}{stroke}\n{indent}    android:pathData="{data}" />'


def convert(svg: Path) -> str:
    root = ET.parse(svg).getroot()
    if root.get("viewBox") != "0 0 24 24":
        raise SystemExit(f"{svg.name} : viewBox inattendue")
    lines = []
    for el in root:
        tag = el.tag.replace(SVG, "")
        filled = el.get("fill") == "currentColor"
        if tag == "path":
            data = el.get("d")
        elif tag == "circle":
            data = circle_path(el)
        elif tag == "rect":
            data = rect_path(el)
        else:
            raise SystemExit(f"{svg.name} : élément <{tag}> non pris en charge")
        transform = el.get("transform")
        if transform:
            match = re.fullmatch(r"rotate\(([-\d.]+) ([-\d.]+) ([-\d.]+)\)", transform)
            if not match:
                raise SystemExit(f"{svg.name} : transformation non prise en charge ({transform})")
            angle, px, py = (num(v) for v in match.groups())
            lines.append(f'    <group android:rotation="{angle}" android:pivotX="{px}" android:pivotY="{py}">')
            lines.append(path_xml(data, filled, "        "))
            lines.append("    </group>")
        else:
            lines.append(path_xml(data, filled, "    "))
    body = "\n".join(lines)
    return (
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        f"<!-- Généré par android/scripts/sync-category-icons.py depuis design/icons/categories/{svg.name}. "
        "Ne pas modifier. -->\n"
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:width="24dp"\n'
        '    android:height="24dp"\n'
        '    android:viewportWidth="24"\n'
        '    android:viewportHeight="24">\n'
        f"{body}\n"
        "</vector>\n"
    )


def main() -> int:
    check = "--check" in sys.argv[1:]
    status = 0
    expected = {}
    for svg in sorted(SRC.glob("*.svg")):
        expected[f"ic_cat_{svg.stem.replace('-', '_')}.xml"] = convert(svg)
    present = {p.name for p in DST.glob("ic_cat_*.xml")}
    for name, content in expected.items():
        target = DST / name
        if check:
            if not target.exists() or target.read_text(encoding="utf-8") != content:
                print(f"::error::{name} diffère de design/icons/categories (lancer android/scripts/sync-category-icons.py)")
                status = 1
        else:
            DST.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
    for stale in sorted(present - expected.keys()):
        if check:
            print(f"::error::{stale} n'a plus de source dans design/icons/categories")
            status = 1
        else:
            (DST / stale).unlink()
    return status


if __name__ == "__main__":
    sys.exit(main())
