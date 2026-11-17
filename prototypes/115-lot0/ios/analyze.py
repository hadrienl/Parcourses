#!/usr/bin/env python3
"""Mesure, image par image, l'écart entre les bouts du trait et leurs perles (#115, lot 0).

Lit trois colonnes de l'enregistrement du simulateur (ffmpeg, sans dépendance Python) :
- le trait (centre de la gouttière, x = 14 pt) : perles et trou éventuel ;
- la sonde (x = 25 pt), copie du trait que les perles ne couvrent pas : bouts et jonction exacts ;
- le témoin de phase (carré coloré en haut à droite).

Usage : analyze.py <video.mov> [--scale 3] [--width-pt 402]
"""
import json
import subprocess
import sys
from collections import defaultdict

PAPER = (250, 250, 250)
COLORS = {
    "red": (255, 0, 0),  # trait parcouru
    "blue": (0, 0, 255),  # trait à parcourir
    "first": (0, 204, 0),
    "next": (255, 0, 255),
    "last": (0, 204, 255),
    "other": (0, 0, 0),
    "paper": PAPER,
}
PHASES = {
    "idle": (128, 128, 128),
    "sort": (255, 255, 0),
    "sortBack": (255, 128, 0),
    "departFirst": (0, 255, 0),
    "departLast": (0, 128, 0),
    "check": (0, 255, 255),
    "insert": (128, 0, 255),
    "flingDown": (255, 0, 0),
    "flingUp": (128, 0, 0),
    "flingSlow": (0, 0, 255),
    "done": (255, 255, 255),
}


def nearest(rgb, table, limit=90):
    best, dist = None, 1e9
    for name, ref in table.items():
        d = sum((a - b) ** 2 for a, b in zip(rgb, ref)) ** 0.5
        if d < dist:
            best, dist = name, d
    return best if dist <= limit else None


def probe(video):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=width,height",
         "-of", "json", video], capture_output=True, check=True, text=True).stdout
    s = json.loads(out)["streams"][0]
    return s["width"], s["height"]


def column_frames(video, x, height):
    """Rend la colonne x de chaque image (une image enregistrée = une image lue, sans rééchantillonnage)."""
    # Largeur et abscisse paires : le H.264 sous-échantillonne la chrominance par 2.
    x -= x % 2
    cmd = ["ffmpeg", "-v", "error", "-i", video, "-fps_mode", "passthrough",
           "-vf", f"crop=2:{height}:{x}:0", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    data = subprocess.run(cmd, capture_output=True, check=True).stdout
    size = height * 6
    # On garde le premier des deux pixels de chaque ligne.
    return [b"".join(data[i + y * 6:i + y * 6 + 3] for y in range(height)) for i in range(0, len(data), size)]


def runs(column, height, table):
    """Suites de pixels de même classe le long de la colonne : [(classe, début, fin)]."""
    result = []
    for y in range(height):
        rgb = tuple(column[y * 3:y * 3 + 3])
        name = nearest(rgb, table) or "?"
        if result and result[-1][0] == name:
            result[-1][2] = y
        else:
            result.append([name, y, y])
    return result


def beads(track_runs, scale):
    """Centres des perles colorées le long du trait : bord haut de l'anneau au bord bas (anneau, fond, anneau)."""
    found = {}
    for role in ("first", "next", "last"):
        ys = [(a, b) for name, a, b in track_runs if name == role and b - a >= 1]
        if not ys:
            continue
        top, bottom = ys[0][0], ys[-1][1]
        diameter = (bottom - top) / scale
        if 10 <= diameter <= 22:  # perle entière à l'écran
            found[role] = (top + bottom) / 2 / scale
    return found


def all_beads(track_runs, scale):
    """Centres de toutes les perles le long du trait (anneaux de toute couleur, noirs compris)."""
    rings = {"first", "next", "last", "other"}
    centers, current = [], None
    for name, a, b in track_runs:
        if name in rings and b - a >= 1:
            if current and a - current[1] <= 20 * scale and (b - current[0]) <= 20 * scale:
                current[1] = b
            else:
                if current:
                    centers.append(current)
                current = [a, b]
    if current:
        centers.append(current)
    return [(a + b) / 2 / scale for a, b in centers if 10 <= (b - a) / scale <= 22]


def track_ends(probe_runs, scale):
    reds = [(a, b) for n, a, b in probe_runs if n == "red" and b - a >= 2]
    blues = [(a, b) for n, a, b in probe_runs if n == "blue" and b - a >= 2]
    if not reds and not blues:
        return None
    top = min([a for a, _ in reds + blues]) / scale
    bottom = max([b for _, b in reds + blues]) / scale
    junction = (min(a for a, _ in blues) / scale) if blues and reds else (top if blues else bottom)
    return top, junction, bottom


def gaps(track_runs, scale):
    """Trous du trait entre deux perles : papier hors d'une perle (une perle = anneau, fond papier, anneau)."""
    inner = [r for r in track_runs if r[0] != "?"]
    start = next((i for i, r in enumerate(inner) if r[0] in ("red", "blue")), None)
    end = next((i for i in range(len(inner) - 1, -1, -1) if inner[i][0] in ("red", "blue")), None)
    if start is None:
        return 0.0
    worst = 0.0
    rings = {"first", "next", "last", "other"}
    for i in range(start, end + 1):
        name, a, b = inner[i]
        if name != "paper":
            continue
        enclosed = 0 < i < len(inner) - 1 and inner[i - 1][0] in rings and inner[i + 1][0] in rings
        length = (b - a + 1) / scale
        if enclosed and length <= 20:
            continue
        worst = max(worst, length)
    return worst


def main():
    video = sys.argv[1]
    scale = float(sys.argv[sys.argv.index("--scale") + 1]) if "--scale" in sys.argv else 3.0
    width, height = probe(video)
    track = column_frames(video, int(14 * scale), height)
    probe_col = column_frames(video, int(25 * scale), height)
    marker = column_frames(video, width - int(20 * scale), height)
    series = [] if "--series" in sys.argv else None
    stats = defaultdict(lambda: {"frames": 0, "top": [], "junction": [], "bottom": [], "gap": 0.0, "worst": {}})
    for index, (t, p, m) in enumerate(zip(track, probe_col, marker)):
        # Témoin : carré de 40 pt au coin haut droit de l'écran.
        sample = tuple(m[int(20 * scale) * 3:int(20 * scale) * 3 + 3])
        phase = nearest(sample, PHASES, limit=120)
        phase = phase or "?"
        track_runs = runs(t, height, COLORS)
        probe_runs = runs(p, height, {"red": COLORS["red"], "blue": COLORS["blue"], "paper": PAPER})
        found = beads(track_runs, scale)
        ends = track_ends(probe_runs, scale)
        s = stats[phase]
        s["frames"] += 1
        if ends:
            top, junction, bottom = ends
            for key, role, value in (("top", "first", top), ("junction", "next", junction), ("bottom", "last", bottom)):
                if role in found:
                    error = value - found[role]
                    s[key].append(error)
                    if abs(error) > abs(s["worst"].get(key, (0, 0))[0]):
                        s["worst"][key] = (round(error, 1), index)
        every = all_beads(track_runs, scale)
        if ends and every:
            top, _, bottom = ends
            # Perle extrême contre bout du trait : écart > 0 en haut = le trait dépasse ; < 0 = perle hors du trait.
            if top > 1 and every[0] > 1:
                s.setdefault("extTop", []).append(every[0] - top)
            if bottom < height / scale - 1:
                s.setdefault("extBottom", []).append(bottom - every[-1])
        if series is not None:
            series.append((index, phase, ends, found.get("next"), every[:1] + every[-1:]))
        g = gaps(track_runs, scale)
        if g > s["gap"]:
            s["gap"] = g
            s["worst"]["gap"] = (round(g, 1), index)

    print(f"{video} : {len(track)} images, {width}×{height} px, échelle {scale}")
    print(f"{'phase':<12}{'images':>7}  {'bout haut (pt)':>22}  {'jonction (pt)':>22}  {'bout bas (pt)':>22}  {'trou max':>9}")
    for phase, s in stats.items():
        def fmt(values):
            if not values:
                return "—"
            worst = max(values, key=abs)
            mean = sum(abs(v) for v in values) / len(values)
            return f"max {worst:+5.1f} moy {mean:4.1f} n={len(values)}"
        print(f"{phase:<12}{s['frames']:>7}  {fmt(s['top']):>22}  {fmt(s['junction']):>22}  {fmt(s['bottom']):>22}  "
              f"{s['gap']:>7.1f}pt  {s['worst']}")
        def ext(values):
            if not values:
                return "—"
            return f"min {min(values):+6.1f} max {max(values):+6.1f}"
        print(f"{'':<12}{'':>7}  perle extrême / bout : haut {ext(s.get('extTop'))}, bas {ext(s.get('extBottom'))}")
    if series:
        for row in series:
            print(row)


if __name__ == "__main__":
    main()
