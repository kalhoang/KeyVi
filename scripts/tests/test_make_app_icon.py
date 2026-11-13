# SPDX-License-Identifier: GPL-3.0-or-later
"""Self-tests for scripts/make-app-icon.py: menu bar glyphs (PRD-R10, PRD-R67, Pa's artwork S7), the app icon set
and the website icons. Standard library only. Run: python3 -I scripts/tests/test_make_app_icon.py"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
import shutil
import struct
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from support import REPO, SCRIPTS, py  # noqa: E402


def load_script():
    spec = importlib.util.spec_from_file_location("make_app_icon", SCRIPTS / "make-app-icon.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses look the module up while the class body runs
    spec.loader.exec_module(module)
    return module


icons = load_script()
CATALOG = REPO / "App" / "Resources" / "Assets.xcassets"
STATIC = REPO / "site" / "static"


def without_comments(svg: str) -> str:
    return re.sub(r"\s*<!--.*?-->", "", svg, flags=re.S)


def colourless(svg: str) -> str:
    """The glyph as someone who cannot tell hues apart sees it: shapes and opacity, no fill or stroke colour."""
    return re.sub(r"#[0-9A-Fa-f]{6}", "#colour", without_comments(svg))


def relative_luminance(hex_colour: str) -> float:
    def channel(value: int) -> float:
        c = value / 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (int(hex_colour[i:i + 2], 16) for i in (1, 3, 5))
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def contrast(a: str, b: str) -> float:
    high, low = sorted((relative_luminance(a), relative_luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def blend(ink: str, opacity: float, background: str) -> str:
    mix = [round(int(ink[i:i + 2], 16) * opacity + int(background[i:i + 2], 16) * (1 - opacity)) for i in (1, 3, 5)]
    return "#" + "".join(f"{v:02X}" for v in mix)


class MenuBarGlyphTests(unittest.TestCase):
    def test_committed_glyphs_are_up_to_date(self):
        result = py("make-app-icon.py", "menu-bar", "--check")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_check_reports_and_write_repairs_a_stale_glyph(self):
        with tempfile.TemporaryDirectory() as tmp:
            catalog = Path(tmp) / "Assets.xcassets"
            for folder in CATALOG.glob("StatusIcon-*.imageset"):
                shutil.copytree(folder, catalog / folder.name)
            stale = catalog / "StatusIcon-paused.imageset" / "paused-dark.svg"
            stale.write_text("<svg/>", encoding="utf-8")
            with contextlib.redirect_stderr(io.StringIO()) as messages:
                self.assertEqual(icons.write_or_check(icons.menu_bar_outputs(catalog=catalog), check=True), 1)
            self.assertIn("paused-dark.svg", messages.getvalue())
            self.assertEqual(icons.write_or_check(icons.menu_bar_outputs(catalog=catalog), check=False), 0)
            self.assertEqual(icons.write_or_check(icons.menu_bar_outputs(catalog=catalog), check=True), 0)

    def test_states_match_the_swift_enum(self):
        source = (REPO / "Packages" / "AppCore" / "Sources" / "ShellCore" / "StatusPresentation.swift").read_text()
        body = source.split("public enum StatusIconState", 1)[1].split("public var", 1)[0]
        self.assertEqual(re.findall(r"^\s*case (\w+)", body, flags=re.M), list(icons.STATES))

    def test_on_and_off_are_pas_files_unchanged(self):
        for (state, variant), name in icons.PA_FILES.items():
            with self.subTest(state=state, variant=variant):
                committed = (CATALOG / f"StatusIcon-{state}.imageset" / f"{state}-{variant}.svg").read_text()
                self.assertEqual(without_comments(committed), without_comments((REPO / "assets" / name).read_text()))
        self.assertEqual({s for s, _ in icons.PA_FILES}, {"vietnamese", "english"})

    def test_every_glyph_is_well_formed_vector_art_with_its_source(self):
        for svg in CATALOG.glob("StatusIcon-*.imageset/*.svg"):
            with self.subTest(svg=svg.name):
                root = ET.fromstring(svg.read_text(encoding="utf-8"))
                self.assertEqual(root.get("viewBox"), "0 0 22 22")
                header = svg.read_text(encoding="utf-8")[:600]
                self.assertIn("Source:", header)
                self.assertIn("CLR-R7", header)

    def test_every_state_differs_without_colour_in_every_variant(self):
        # PRD-R10 and PRD-R67: no state is told apart by hue alone.
        for variant in icons.VARIANTS:
            with self.subTest(variant=variant):
                shapes = {state: colourless((CATALOG / f"StatusIcon-{state}.imageset" / f"{state}-{variant}.svg")
                                            .read_text(encoding="utf-8")) for state in icons.STATES}
                self.assertEqual(len(set(shapes.values())), len(icons.STATES))

    def test_image_sets_carry_four_appearances_and_keep_their_colours(self):
        for state in icons.STATES:
            with self.subTest(state=state):
                folder = CATALOG / f"StatusIcon-{state}.imageset"
                contents = json.loads((folder / "Contents.json").read_text())
                self.assertEqual(contents["properties"]["template-rendering-intent"], "original")
                self.assertTrue(contents["properties"]["preserves-vector-representation"])
                found = {tuple(sorted(a["value"] for a in image.get("appearances", []))) for image in contents["images"]}
                self.assertEqual(found, {(), ("dark",), ("high",), ("dark", "high")})
                self.assertEqual(sorted(p.name for p in folder.iterdir()),
                                 sorted(["Contents.json"] + [f"{state}-{v}.svg" for v in icons.VARIANTS]))

    def test_high_contrast_glyphs_reach_3_to_1_on_their_menu_bar(self):
        mark = icons.load_mark()
        for variant, background in (("light-hc", "#FFFFFF"), ("dark-hc", "#000000")):
            palette = mark.palettes[variant]
            with self.subTest(variant=variant):
                for colour in (palette.ink, palette.on_dot, palette.off_dot, palette.alert):
                    self.assertGreaterEqual(contrast(colour, background), 3.0, colour)
                for opacity in (float(mark.off_opacity), float(palette.faint)):
                    dimmed = blend(palette.ink, opacity, background)
                    self.assertGreaterEqual(contrast(dimmed, background), 3.0, f"letters at {opacity}")
                # Solid and dimmed letters (Vietnamese and English) are told apart by lightness alone.
                self.assertGreaterEqual(contrast(palette.ink, blend(palette.ink, float(mark.off_opacity), background)), 3.0)

    def test_letters_reach_3_to_1_on_every_menu_bar_in_every_variant(self):
        # PRD-R67: the KV mark itself (solid, Pa's off opacity and the faint paused / not-working letters) stays at
        # 3:1 or more in the normal palettes too, against pure white or black and a typical opaque menu bar sample.
        # Pa's grey off dot is excluded on purpose: colour is only an extra cue there (the letters carry the state).
        mark = icons.load_mark()
        bars = {"light": ("#FFFFFF", "#ECECEC"), "light-hc": ("#FFFFFF", "#ECECEC"),
                "dark": ("#000000", "#1E1E1E"), "dark-hc": ("#000000", "#1E1E1E")}
        for variant, backgrounds in bars.items():
            palette = mark.palettes[variant]
            for background in backgrounds:
                for opacity in (1.0, float(mark.off_opacity), float(palette.faint)):
                    with self.subTest(variant=variant, background=background, opacity=opacity):
                        dimmed = blend(palette.ink, opacity, background)
                        self.assertGreaterEqual(contrast(dimmed, background), 3.0)
                with self.subTest(variant=variant, background=background, badge="recording"):
                    self.assertGreaterEqual(contrast(palette.alert, background), 3.0)


def png_pixels(path: Path) -> tuple[int, int, list[bytes]]:
    """Decodes an 8-bit, non-interlaced RGBA PNG into rows of bytes (enough for the icon checks)."""
    data = path.read_bytes()
    width, height, depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", data[16:29])
    assert (depth, color_type, interlace) == (8, 6, 0), f"{path.name}: not 8-bit RGBA"
    chunks, offset = b"", 8
    while offset < len(data):
        length, kind = struct.unpack(">I4s", data[offset:offset + 8])
        if kind == b"IDAT":
            chunks += data[offset + 8:offset + 8 + length]
        offset += 12 + length
    raw, stride, rows, previous = zlib.decompress(chunks), width * 4, [], bytes(width * 4)
    for y in range(height):
        kind, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            left = line[x - 4] if x >= 4 else 0
            up, up_left = previous[x], previous[x - 4] if x >= 4 else 0
            if kind == 1:
                line[x] = (line[x] + left) & 0xFF
            elif kind == 2:
                line[x] = (line[x] + up) & 0xFF
            elif kind == 3:
                line[x] = (line[x] + (left + up) // 2) & 0xFF
            elif kind == 4:
                p = left + up - up_left
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
                line[x] = (line[x] + (left if pa <= pb and pa <= pc else up if pb <= pc else up_left)) & 0xFF
        rows.append(bytes(line))
        previous = rows[-1]
    return width, height, rows


def png_size(path: Path) -> tuple[int, int, int]:
    width, height, _, color_type = struct.unpack(">IIBB", path.read_bytes()[16:26])
    return width, height, color_type


class AppIconTests(unittest.TestCase):
    FOLDER = CATALOG / "AppIcon.appiconset"

    def test_contents_list_every_macos_slot(self):
        self.assertEqual((self.FOLDER / "Contents.json").read_text(), icons.app_icon_contents())
        slots = {(size, scale) for size, scale, _ in icons.app_icon_entries()}
        expected = {(f"{p}x{p}", s) for p in (16, 32, 128, 256, 512) for s in (1, 2)}
        self.assertEqual(slots, expected)

    def test_every_file_has_its_pixel_size_and_an_alpha_channel(self):
        for size, scale, name in icons.app_icon_entries():
            with self.subTest(name=name):
                pixels = int(size.split("x")[0]) * scale
                self.assertEqual(png_size(self.FOLDER / name), (pixels, pixels, 6))

    def test_keycap_is_cut_out_and_sits_on_the_macos_grid(self):
        # 128 px: the grid body spans 12.5 to 115.5 px; outside it only the soft shadow remains.
        width, _, rows = png_pixels(self.FOLDER / "icon_128x128.png")
        alpha = lambda x, y: rows[y][x * 4 + 3]  # noqa: E731
        middle = width // 2
        for x, y in ((0, 0), (127, 0), (0, 127), (6, middle), (middle, 6), (121, middle)):
            self.assertLess(alpha(x, y), 8, f"({x}, {y}) should be transparent")
        for x, y in ((middle, middle), (16, middle), (middle, 16), (111, middle), (middle, 111)):
            self.assertEqual(alpha(x, y), 255, f"({x}, {y}) should be the opaque keycap")
        self.assertLess(alpha(14, 14), 255, "the corner is rounded")


class SiteIconTests(unittest.TestCase):
    def test_favicon_svg_is_the_kv_mark_with_its_source(self):
        text = (STATIC / "favicon.svg").read_text(encoding="utf-8")
        self.assertEqual(text, icons.favicon_svg(icons.load_mark()))
        ET.fromstring(text)
        self.assertIn("Source:", text[:400])
        self.assertIn("CLR-R7", text[:400])

    def test_raster_icons_have_the_expected_sizes(self):
        self.assertEqual(png_size(STATIC / "apple-touch-icon.png"), (180, 180, 2))  # opaque for iOS
        for pixels in (64, 128):
            self.assertEqual(png_size(STATIC / "assets" / "brand" / f"app-icon-{pixels}.png"), (pixels, pixels, 6))
        ico = (STATIC / "favicon.ico").read_bytes()
        reserved, kind, count = struct.unpack("<HHH", ico[:6])
        self.assertEqual((reserved, kind), (0, 1))
        sizes = {(ico[6 + 16 * i] or 256) for i in range(count)}
        self.assertEqual(sizes, {16, 32, 48})


class FakeGrayImage:
    """Just enough of a Pillow image for keycap_box: convert("L"), size and getpixel."""

    def __init__(self, width: int, height: int, background: int, keycap: tuple[int, int, int, int] | None = None):
        self.size, self.background, self.keycap = (width, height), background, keycap

    def convert(self, mode: str) -> FakeGrayImage:
        return self

    def getpixel(self, point: tuple[int, int]) -> int:
        if self.keycap is None:
            return self.background
        left, top, right, bottom = self.keycap
        inside = left <= point[0] < right and top <= point[1] < bottom
        return self.background - 80 if inside else self.background


class GeometryTests(unittest.TestCase):
    def test_keycap_box_reports_a_missing_keycap_clearly(self):
        with self.assertRaisesRegex(ValueError, "keycap edge not found"):
            icons.keycap_box(FakeGrayImage(64, 64, background=240))

    def test_keycap_box_mirrors_the_left_and_top_edges(self):
        self.assertEqual(icons.keycap_box(FakeGrayImage(100, 80, 240, keycap=(20, 10, 80, 70))), (20, 10, 80, 70))

    def test_touch_crop_is_a_square_centred_on_the_keycap(self):
        # Pa's current artwork (left == top) and boxes where the keycap is not equidistant from both edges.
        for box in ((228, 228, 796, 796), (20, 10, 80, 70), (40, 10, 80, 90), (5, 30, 105, 70)):
            with self.subTest(box=box):
                x0, y0, x1, y1 = icons.touch_crop_box(box)
                self.assertEqual(x1 - x0, y1 - y0)
                self.assertEqual((x0 + x1, y0 + y1), (box[0] + box[2], box[1] + box[3]))
                self.assertLessEqual((x0, y0), (box[0], box[1]))
                self.assertGreaterEqual((x1, y1), (box[2], box[3]))
        side = 796 - 228
        self.assertEqual(icons.touch_crop_box((228, 228, 796, 796)),
                         (228 - side // 8, 228 - side // 8, 796 + side // 8, 796 + side // 8))


class CommandLineTests(unittest.TestCase):
    def test_help_and_check_need_no_imaging_library(self):
        self.assertEqual(py("make-app-icon.py", "--help").returncode, 0)
        result = py("make-app-icon.py", "app-icon", "--check")
        self.assertEqual(result.returncode, 2)
        self.assertIn("menu-bar only", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
