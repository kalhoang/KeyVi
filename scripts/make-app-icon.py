#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: LicenseRef-App-Pending
"""Builds the app's icons from Pa's own artwork in assets/ (CLR-R7, Pa's decision S7 of 2026-11-13).

Subcommands:
  menu-bar   App/Resources/Assets.xcassets/StatusIcon-<state>.imageset (PRD-R10). Standard library only.
             Each set holds four SVGs (light, dark, light high contrast, dark high contrast menu bars) and is
             not a template: AppKit picks the variant from the status button's effective appearance when it
             draws, which follows the menu bar over a dark or tinted wallpaper and Increase Contrast.
             `vietnamese` and `english` are Pa's on and off files; the other states put a badge in the dot's
             place so every state differs in shape, not only in colour (PRD-R10, PRD-R67).
  app-icon   App/Resources/Assets.xcassets/AppIcon.appiconset (16 to 512 pt at 1x and 2x). Needs Pillow.
             Cuts the photographed keycap out of its off-white background with a rounded-square mask, adds a
             soft shadow and places it on Apple's macOS icon grid (an 824 px body on a 1024 px canvas).
  site       site/static: favicon.svg (the KV mark on a keycap plate), favicon.ico, apple-touch-icon.png and
             the header logo in assets/brand/. Needs Pillow.
  all        every output above.

Usage:
  python3 -I scripts/make-app-icon.py menu-bar [--check]
  uv run --with pillow python -I scripts/make-app-icon.py all
`--check` (menu-bar only) compares instead of writing and exits 1 when a committed file is stale.
"""
from __future__ import annotations

import argparse
import json
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
ASSETS = REPO_ROOT / "assets"
LOGO = ASSETS / "keyvi_logo.png"
CATALOG = REPO_ROOT / "App" / "Resources" / "Assets.xcassets"
SITE_STATIC = REPO_ROOT / "site" / "static"
SVG_NS = "http://www.w3.org/2000/svg"

# ---------------------------------------------------------------------------------------------------------------
# Menu bar glyphs
# ---------------------------------------------------------------------------------------------------------------

# Variant name -> (Pa's file it comes from, asset catalog appearances). The high-contrast variants reuse the
# geometry with the stronger palette below.
VARIANTS = {
    "light": [],
    "dark": [{"appearance": "luminosity", "value": "dark"}],
    "light-hc": [{"appearance": "contrast", "value": "high"}],
    "dark-hc": [{"appearance": "luminosity", "value": "dark"}, {"appearance": "contrast", "value": "high"}],
}


@dataclass(frozen=True)
class Palette:
    ink: str  # letters and monochrome badges
    on_dot: str  # emerald dot of the on state
    off_dot: str  # gray dot of the off state
    alert: str  # centre of the recording badge
    # Letter opacity of the paused and not-working glyphs: 0.5 keeps the KV mark at 3:1 or more on a light
    # menu bar (3.45:1 on white, 3.30:1 on #ECECEC) as PRD-R67 requires; the badge tells them apart from English.
    faint: str = "0.5"


# Increase Contrast: pure ink and dots with at least 3:1 against the menu bar (WCAG AA for graphics, PRD-R67).
HIGH_CONTRAST = {
    "light-hc": Palette(ink="#000000", on_dot="#007A55", off_dot="#4B5563", alert="#B3001B"),
    "dark-hc": Palette(ink="#FFFFFF", on_dot="#3DDC97", off_dot="#B4BAC4", alert="#FF8A8A"),
}
ALERT = {"light": "#D93036", "dark": "#FF6369"}


@dataclass(frozen=True)
class Glyph:
    letters: str  # "on" (solid), "off" (Pa's off opacity) or "faint"
    badge: str  # what sits in the dot's place


# PRD-R10 states. Without colour: solid or dimmed letters, then the badge shape (filled dot, ring, lock,
# pause bars, slash, recording ring) tell every state apart.
STATES = {
    "vietnamese": Glyph("on", "dot-on"),
    "english": Glyph("off", "dot-off"),
    "ignoredApp": Glyph("off", "ring"),
    "secureInputVietnamese": Glyph("on", "lock"),
    "secureInputEnglish": Glyph("off", "lock"),
    "paused": Glyph("faint", "pause"),
    "notWorking": Glyph("faint", "slash"),
    "capturing": Glyph("on", "record"),
}
PA_FILES = {("vietnamese", "light"): "keyvi_menubar_on_light.svg", ("vietnamese", "dark"): "keyvi_menubar_on_dark.svg",
            ("english", "light"): "keyvi_menubar_off_light.svg", ("english", "dark"): "keyvi_menubar_off_dark.svg"}


@dataclass(frozen=True)
class Mark:
    """The KV mark of Pa's menu bar SVGs: letter shapes, the dot and the opacity of the off state."""

    shapes: tuple[str, ...]
    dot: dict[str, str]
    off_opacity: str
    palettes: dict[str, Palette]


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _parse_pa_file(path: Path) -> tuple[ET.Element, ET.Element]:
    root = ET.parse(path).getroot()
    circle = next(e for e in root if _local(e.tag) == "circle")
    group = next(e for e in root if _local(e.tag) == "g")
    return circle, group


def _shape_markup(element: ET.Element) -> str:
    attributes = " ".join(f'{key}="{value}"' for key, value in element.attrib.items())
    return f"<{_local(element.tag)} {attributes}/>"


def load_mark(assets: Path = ASSETS) -> Mark:
    on_circle, on_group = _parse_pa_file(assets / PA_FILES[("vietnamese", "light")])
    palettes = dict(HIGH_CONTRAST)
    off_opacity = ""
    for variant in ("light", "dark"):
        on_dot, on_letters = _parse_pa_file(assets / PA_FILES[("vietnamese", variant)])
        off_dot, off_letters = _parse_pa_file(assets / PA_FILES[("english", variant)])
        off_opacity = off_letters.get("opacity", "1")
        palettes[variant] = Palette(
            ink=on_letters.get("fill"), on_dot=on_dot.get("fill"), off_dot=off_dot.get("fill"), alert=ALERT[variant])
    shapes = tuple(_shape_markup(child) for child in on_group)
    dot = {key: on_circle.get(key) for key in ("cx", "cy", "r")}
    return Mark(shapes=shapes, dot=dot, off_opacity=off_opacity, palettes=palettes)


def _letters(mark: Mark, glyph: Glyph, palette: Palette) -> str:
    opacity = {"on": "", "off": f' opacity="{mark.off_opacity}"', "faint": f' opacity="{palette.faint}"'}
    body = "\n".join(f"    {shape}" for shape in mark.shapes)
    return f'  <g fill="{palette.ink}"{opacity[glyph.letters]}>\n{body}\n  </g>'


def _badge(mark: Mark, glyph: Glyph, palette: Palette) -> str:
    cx, cy, r = (float(mark.dot[key]) for key in ("cx", "cy", "r"))
    dim = f' opacity="{mark.off_opacity}"' if glyph.letters == "off" else ""
    if glyph.badge in ("dot-on", "dot-off"):
        fill = palette.on_dot if glyph.badge == "dot-on" else palette.off_dot
        return f'  <circle cx="{cx:g}" cy="{cy:g}" r="{r:g}" fill="{fill}"/>'
    if glyph.badge == "ring":
        return (f'  <circle cx="{cx:g}" cy="{cy:g}" r="{r - 0.15:g}" fill="none" stroke="{palette.ink}" '
                f'stroke-width="0.9"{dim}/>')
    if glyph.badge == "lock":
        return (f'  <g{dim}>\n'
                f'    <rect x="{cx - 1.8:g}" y="3.3" width="3.6" height="3" rx="0.5" fill="{palette.ink}"/>\n'
                f'    <path d="M{cx - 1:g} 3.4 V2.3 A1 1 0 0 1 {cx + 1:g} 2.3 V3.4" fill="none" '
                f'stroke="{palette.ink}" stroke-width="0.8"/>\n  </g>')
    if glyph.badge == "pause":
        bars = [f'    <rect x="{x:g}" y="1.9" width="1.1" height="4.4" rx="0.35"/>' for x in (cx - 1.6, cx + 0.5)]
        return f'  <g fill="{palette.ink}">\n' + "\n".join(bars) + "\n  </g>"
    if glyph.badge == "slash":
        return f'  <line x1="2" y1="2" x2="20" y2="20" stroke="{palette.ink}" stroke-width="1.6" stroke-linecap="round"/>'
    if glyph.badge == "record":
        return (f'  <circle cx="{cx:g}" cy="3.6" r="2.35" fill="none" stroke="{palette.ink}" stroke-width="0.8"/>\n'
                f'  <circle cx="{cx:g}" cy="3.6" r="1.25" fill="{palette.alert}"/>')
    raise ValueError(f"unknown badge {glyph.badge}")


def source_comment(state: str, variant: str) -> str:
    pa_file = PA_FILES.get((state, variant))
    origin = f"Pa's own artwork assets/{pa_file}" if pa_file else "derived from Pa's own artwork assets/keyvi_menubar_*.svg"
    return (f"<!-- Menu bar glyph {state}, {variant} menu bar. Source: {origin}, generated by "
            f"scripts/make-app-icon.py (CLR-R7). Do not edit by hand. -->")


def menu_bar_svg(mark: Mark, state: str, variant: str, assets: Path = ASSETS) -> str:
    """Pa's files are copied as they are, with a source comment; every other glyph is built from the mark."""
    comment = source_comment(state, variant)
    pa_file = PA_FILES.get((state, variant))
    if pa_file:
        text = (assets / pa_file).read_text(encoding="utf-8")
        head, rest = text.split("\n", 1)
        return f"{head}\n  {comment}\n{rest}"
    glyph, palette = STATES[state], mark.palettes[variant]
    body = [_letters(mark, glyph, palette), _badge(mark, glyph, palette)]
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 22 22" width="22" height="22">\n'
            f"  {comment}\n" + "\n".join(body) + "\n</svg>\n")


def imageset_contents(state: str) -> str:
    images = []
    for variant, appearances in VARIANTS.items():
        entry: dict = {"filename": f"{state}-{variant}.svg", "idiom": "universal"}
        if appearances:
            entry = {"appearances": appearances, **entry}
        images.append(entry)
    contents = {
        "images": images,
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "original"},
    }
    return json.dumps(contents, indent=2, separators=(",", " : ")) + "\n"


def menu_bar_outputs(assets: Path = ASSETS, catalog: Path = CATALOG) -> dict[Path, str]:
    mark = load_mark(assets)
    outputs: dict[Path, str] = {}
    for state in STATES:
        folder = catalog / f"StatusIcon-{state}.imageset"
        outputs[folder / "Contents.json"] = imageset_contents(state)
        for variant in VARIANTS:
            outputs[folder / f"{state}-{variant}.svg"] = menu_bar_svg(mark, state, variant, assets)
    return outputs


def write_or_check(outputs: dict[Path, str], check: bool) -> int:
    stale = []
    for path, text in outputs.items():
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current == text:
            continue
        if check:
            stale.append(path)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    for folder in {path.parent for path in outputs}:
        extra = sorted(p for p in folder.iterdir() if p not in outputs) if folder.exists() else []
        stale.extend(extra)
        if extra and not check:
            print(f"error: {folder.name} has files this script does not generate: {[p.name for p in extra]}",
                  file=sys.stderr)
            return 1
    for path in stale:
        print(f"stale: {_display(path)}", file=sys.stderr)
    return 1 if stale else 0


def _display(path: Path) -> str:
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


# ---------------------------------------------------------------------------------------------------------------
# App icon (Pillow)
# ---------------------------------------------------------------------------------------------------------------

# Measured on assets/keyvi_logo.png: the keycap is a rounded square whose corner radius is 0.229 of its side
# (130 px on 568 px), close to the macOS icon shape.
KEYCAP_CORNER_RATIO = 0.229
EDGE_THRESHOLD = 18  # grey levels darker than the background that mark the keycap's outer edge
CANVAS = 1024
BODY = 824  # Apple's macOS icon grid: the body is 824 x 824 px, centred on the 1024 px canvas
# Soft shadow under the keycap: (y offset, blur radius, opacity), a tight contact shadow and a wider one.
SHADOWS = ((4, 4, 0.20), (12, 16, 0.22))
ICON_POINTS = (16, 32, 128, 256, 512)
SHARPEN_AT_OR_BELOW = 64  # px; small sizes get a light unsharp mask so the KV mark stays readable
TIGHT_BOX = (84, 84, 940, 940)  # the body and most of its shadow, for favicons and the site header


def _pillow():
    try:
        from PIL import Image, ImageDraw, ImageFilter
    except ImportError:
        sys.exit("error: this subcommand needs Pillow, for example: uv run --with pillow python -I "
                 "scripts/make-app-icon.py app-icon")
    return Image, ImageDraw, ImageFilter


def keycap_box(image) -> tuple[int, int, int, int]:
    """Left and top edges on the centre row and column, mirrored: the keycap is centred in Pa's artwork and
    its shadow falls to the right and below, so the right and bottom edges are not measured directly."""
    gray = image.convert("L")
    width, height = gray.size
    background = gray.getpixel((width // 2, 2))

    def first_edge(values: list[int]) -> int:
        edge = next((i for i, value in enumerate(values) if background - value > EDGE_THRESHOLD), None)
        if edge is None:
            raise ValueError("keycap edge not found in the artwork")
        return edge

    left = first_edge([gray.getpixel((x, height // 2)) for x in range(width // 2)])
    top = first_edge([gray.getpixel((width // 2, y)) for y in range(height // 2)])
    return left, top, width - left, height - top


def touch_crop_box(box: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    """A square around the keycap with an eighth of its side as margin, centred on the keycap even when the box
    is not square, so resizing to the touch icon never distorts it."""
    left, top, right, bottom = box
    width, height = right - left, bottom - top
    side = max(width, height)
    pad = side // 8
    x0, y0 = left + (width - side) // 2 - pad, top + (height - side) // 2 - pad
    return x0, y0, x0 + side + 2 * pad, y0 + side + 2 * pad


def rounded_mask(side: int, radius: float, supersample: int = 4):
    Image, ImageDraw, _ = _pillow()
    big = Image.new("L", (side * supersample, side * supersample), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        (0, 0, side * supersample - 1, side * supersample - 1), radius=radius * supersample, fill=255)
    return big.resize((side, side), Image.Resampling.LANCZOS)


def _shadow(alpha, offset: int, blur: int, opacity: float):
    Image, _, ImageFilter = _pillow()
    margin = (CANVAS - BODY) // 2
    shade = Image.new("L", (CANVAS, CANVAS), 0)
    shade.paste(alpha.point(lambda value: round(value * opacity)), (margin, margin + offset))
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    layer.putalpha(shade.filter(ImageFilter.GaussianBlur(blur)))
    return layer


def app_icon_master(source):
    """The keycap on a transparent 1024 px canvas: opaque crop, scaled to the grid body, then masked."""
    Image, _, _ = _pillow()
    box = keycap_box(source)
    if box[2] - box[0] <= 0 or box[3] - box[1] <= 0:
        raise ValueError("keycap not found in the artwork")
    body = source.convert("RGB").crop(box).resize((BODY, BODY), Image.Resampling.LANCZOS).convert("RGBA")
    body.putalpha(rounded_mask(BODY, BODY * KEYCAP_CORNER_RATIO))
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    for offset, blur, opacity in SHADOWS:
        canvas.alpha_composite(_shadow(body.getchannel("A"), offset, blur, opacity))
    margin = (CANVAS - BODY) // 2
    canvas.alpha_composite(body, (margin, margin))
    return canvas


def scaled(master, pixels: int):
    Image, _, ImageFilter = _pillow()
    image = master.resize((pixels, pixels), Image.Resampling.LANCZOS)
    if pixels > SHARPEN_AT_OR_BELOW:
        return image
    red, green, blue, alpha = image.split()
    sharp = Image.merge("RGB", (red, green, blue)).filter(ImageFilter.UnsharpMask(radius=0.8, percent=60, threshold=0))
    sharp.putalpha(alpha)
    return sharp


def app_icon_entries() -> list[tuple[str, int, str]]:
    """(size in points, scale, file name) for every macOS slot of an app icon set."""
    entries = []
    for points in ICON_POINTS:
        for scale in (1, 2):
            suffix = "" if scale == 1 else "@2x"
            entries.append((f"{points}x{points}", scale, f"icon_{points}x{points}{suffix}.png"))
    return entries


def app_icon_contents() -> str:
    images = [{"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": size}
              for size, scale, name in app_icon_entries()]
    return json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2,
                      separators=(",", " : ")) + "\n"


def write_app_icon(source_path: Path = LOGO, catalog: Path = CATALOG) -> None:
    Image, _, _ = _pillow()
    master = app_icon_master(Image.open(source_path))
    folder = catalog / "AppIcon.appiconset"
    folder.mkdir(parents=True, exist_ok=True)
    for size, scale, name in app_icon_entries():
        pixels = int(size.split("x")[0]) * scale
        scaled(master, pixels).save(folder / name, optimize=True)
    (folder / "Contents.json").write_text(app_icon_contents(), encoding="utf-8")


# ---------------------------------------------------------------------------------------------------------------
# Website icons
# ---------------------------------------------------------------------------------------------------------------

FAVICON_PLATE = {"fill": "#F1F0EC", "stroke": "#CFCBC3"}
FAVICON_SCALE = 2.3  # the 22 pt mark drawn about 42 px wide on the 64 px favicon


def favicon_svg(mark: Mark) -> str:
    palette = mark.palettes["light"]
    cx, cy, r = (float(mark.dot[key]) for key in ("cx", "cy", "r"))
    # Centre the mark's bounding box (letters from x 1.8 to 20, the dot's top to the letters' foot) on the plate.
    centre_x, centre_y = (1.8 + 20.0) / 2, (cy - r + 18.5) / 2
    tx, ty = 32 - centre_x * FAVICON_SCALE, 32 - centre_y * FAVICON_SCALE
    shapes = "\n".join(f"      {shape}" for shape in mark.shapes)
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">\n'
        "  <!-- Website favicon. Source: derived from Pa's own artwork assets/keyvi_logo.png and "
        "assets/keyvi_menubar_on_light.svg, generated by scripts/make-app-icon.py (CLR-R7). -->\n"
        f'  <rect x="2" y="2" width="60" height="60" rx="14" fill="{FAVICON_PLATE["fill"]}" '
        f'stroke="{FAVICON_PLATE["stroke"]}" stroke-width="1.5"/>\n'
        f'  <g transform="translate({tx:.2f} {ty:.2f}) scale({FAVICON_SCALE})">\n'
        f'    <g fill="{palette.ink}">\n{shapes}\n    </g>\n'
        f'    <circle cx="{cx:g}" cy="{cy:g}" r="{r:g}" fill="{palette.on_dot}"/>\n'
        "  </g>\n</svg>\n")


def write_site_icons(source_path: Path = LOGO, static: Path = SITE_STATIC, assets: Path = ASSETS) -> None:
    Image, _, _ = _pillow()
    source = Image.open(source_path)
    tight = app_icon_master(source).crop(TIGHT_BOX)
    (static / "favicon.svg").write_text(favicon_svg(load_mark(assets)), encoding="utf-8")
    tight.resize((256, 256), Image.Resampling.LANCZOS).save(
        static / "favicon.ico", format="ICO", sizes=[(16, 16), (32, 32), (48, 48)])
    # Home-screen icons must be opaque (iOS fills transparency with black): Pa's photo, centred on the keycap.
    touch = source.convert("RGB").crop(touch_crop_box(keycap_box(source)))
    touch.resize((180, 180), Image.Resampling.LANCZOS).save(static / "apple-touch-icon.png", optimize=True)
    brand = static / "assets" / "brand"
    brand.mkdir(parents=True, exist_ok=True)
    for pixels in (64, 128):
        scaled(tight, pixels).save(brand / f"app-icon-{pixels}.png", optimize=True)


# ---------------------------------------------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Build the app icon, menu bar glyphs and website icons from assets/.")
    parser.add_argument("target", choices=["menu-bar", "app-icon", "site", "all"])
    parser.add_argument("--check", action="store_true", help="menu-bar only: exit 1 when a committed file is stale")
    args = parser.parse_args(argv)
    if args.check and args.target != "menu-bar":
        parser.error("--check works with menu-bar only (the PNG outputs depend on the Pillow version)")
    status = 0
    if args.target in ("menu-bar", "all"):
        status = write_or_check(menu_bar_outputs(), args.check)
    if args.target in ("app-icon", "all"):
        write_app_icon()
    if args.target in ("site", "all"):
        write_site_icons()
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
