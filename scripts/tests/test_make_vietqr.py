# SPDX-License-Identifier: GPL-3.0-or-later
"""Self-tests for scripts/make-vietqr.py (PRD-R59, Pa's decision S8). Standard library only; the decode check of the
committed image runs when OpenCV is installed (ShellCoreTests' DonationQRTests decodes it with Core Image on every
run). Run: python3 -I scripts/tests/test_make_vietqr.py"""
from __future__ import annotations

import binascii
import importlib.util
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from support import REPO, SCRIPTS, py  # noqa: E402


def load_script():
    spec = importlib.util.spec_from_file_location("make_vietqr", SCRIPTS / "make-vietqr.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses look the module up while the class body runs
    spec.loader.exec_module(module)
    return module


vietqr = load_script()
APP_IMAGE = REPO / "App" / "Resources" / "Donation.xcassets" / "DonationVietQR.imageset" / "vietqr.png"
SITE_IMAGE = REPO / "site" / "static" / "assets" / "qr" / "vietqr.png"
# Pa's account (S8) with a purpose that names no product, so a rename (scripts/rename-app.sh) keeps this literal.
PAYLOAD = ("00020101021138530010A0000007270123000697044801096886886780208QRIBFTTA53037045802VN"
           "62100806Ung ho6304DDE1")


def expected_payload(purpose: str) -> str:
    """Assembled by hand, with Python's own CRC-CCITT as the independent checksum."""
    body = ("00020101021138530010A0000007270123000697044801096886886780208QRIBFTTA53037045802VN"
            f"62{len(purpose) + 4:02d}08{len(purpose):02d}{purpose}6304")
    return body + f"{binascii.crc_hqx(body.encode('ascii'), 0xFFFF):04X}"


class ChecksumTests(unittest.TestCase):
    def test_standard_check_value(self):
        # CRC-16/CCITT-FALSE catalogue check value.
        self.assertEqual(vietqr.crc16_ccitt_false(b"123456789"), 0x29B1)

    def test_matches_an_independent_implementation(self):
        for data in (b"", b"6304", PAYLOAD[:-4].encode("ascii"), bytes(range(256))):
            with self.subTest(data=data[:12]):
                self.assertEqual(vietqr.crc16_ccitt_false(data), binascii.crc_hqx(data, 0xFFFF))

    def test_detects_a_changed_payload(self):
        self.assertTrue(vietqr.crc_is_valid(PAYLOAD))
        self.assertFalse(vietqr.crc_is_valid(PAYLOAD.replace("688688678", "688688679")))
        self.assertFalse(vietqr.crc_is_valid(PAYLOAD[:-4] + "0000"))


class TlvTests(unittest.TestCase):
    def test_encodes_tag_length_value(self):
        self.assertEqual(vietqr.tlv("00", "01"), "000201")
        self.assertEqual(vietqr.tlv("08", "Ung ho"), "0806Ung ho")
        self.assertEqual(vietqr.tlv("62", ""), "6200")

    def test_rejects_bad_tags_and_long_values(self):
        for tag in ("0", "ab", "123"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                vietqr.tlv(tag, "x")
        with self.assertRaises(ValueError):
            vietqr.tlv("01", "x" * 100)

    def test_parse_is_the_inverse_of_encode(self):
        objects = [("00", "01"), ("26", "nested"), ("99", "x" * 99)]
        self.assertEqual(vietqr.parse_tlv("".join(vietqr.tlv(t, v) for t, v in objects)), objects)

    def test_parse_rejects_truncated_objects(self):
        for text in ("0005ab", "00", "0x02ab"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                vietqr.parse_tlv(text)


class PayloadTests(unittest.TestCase):
    def test_known_payload_for_pas_account(self):
        self.assertEqual(vietqr.vietqr_payload("970448", "688688678", "Ung ho"), PAYLOAD)
        purpose = vietqr.default_purpose()
        self.assertEqual(vietqr.vietqr_payload("970448", "688688678", purpose), expected_payload(purpose))

    def test_fields_follow_the_napas_profile(self):
        top = dict(vietqr.parse_tlv(PAYLOAD))
        self.assertEqual([t for t, _ in vietqr.parse_tlv(PAYLOAD)], ["00", "01", "38", "53", "58", "62", "63"])
        self.assertEqual((top["00"], top["01"], top["53"], top["58"]), ("01", "11", "704", "VN"))
        merchant = dict(vietqr.parse_tlv(top["38"]))
        self.assertEqual(merchant["00"], "A000000727")
        self.assertEqual(merchant["02"], "QRIBFTTA")
        self.assertEqual(dict(vietqr.parse_tlv(merchant["01"])), {"00": "970448", "01": "688688678"})
        self.assertEqual(dict(vietqr.parse_tlv(top["62"])), {"08": "Ung ho"})

    def test_no_account_holder_or_merchant_name(self):
        # S8: the holder's name is never shown; the payer's bank app looks it up after the scan.
        tags = [t for t, _ in vietqr.parse_tlv(PAYLOAD)]
        self.assertNotIn("59", tags)
        self.assertNotIn("60", tags)

    def test_purpose_drops_vietnamese_diacritics(self):
        self.assertEqual(vietqr.ascii_text("Ủng hộ Xuôi"), "Ung ho Xuoi")
        self.assertEqual(vietqr.ascii_text("Đi đâu"), "Di dau")
        with self.assertRaises(ValueError):
            vietqr.ascii_text("Ủng hộ 中")

    def test_default_purpose_names_the_app_from_the_brand_file(self):
        self.assertEqual(vietqr.default_purpose(), f"Ung ho {vietqr.display_name()}")
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / "brand.env"
            env.write_text('APP_SLUG="x"\nAPP_DISPLAY_NAME="Xuôi"\n', encoding="utf-8")
            self.assertEqual(vietqr.default_purpose(env), "Ung ho Xuoi")

    def test_rejects_invalid_inputs(self):
        cases = [("97044", "1", "x"), ("97044a", "1", "x"), ("970448", "", "x"), ("970448", "1" * 20, "x"),
                 ("970448", "12-34", "x"), ("970448", "1", ""), ("970448", "1", "x" * 26)]
        for bank_bin, account, purpose in cases:
            with self.subTest(bin=bank_bin, account=account, purpose=purpose[:5]), self.assertRaises(ValueError):
                vietqr.vietqr_payload(bank_bin, account, purpose)


class CommandLineTests(unittest.TestCase):
    def test_print_payload_needs_no_imaging_library(self):
        result = py("make-vietqr.py", "--print-payload")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), expected_payload(vietqr.default_purpose()))

    def test_invalid_account_exits_2(self):
        result = py("make-vietqr.py", "--print-payload", "--account", "12-34")
        self.assertEqual(result.returncode, 2)
        self.assertIn("account", result.stderr)


def png_header(path: Path) -> tuple[int, int, int]:
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path} is not a PNG"
    width, height, _, color_type = struct.unpack(">IIBB", data[16:26])
    return width, height, color_type


class CommittedImageTests(unittest.TestCase):
    def test_app_and_website_ship_the_same_image(self):
        self.assertEqual(APP_IMAGE.read_bytes(), SITE_IMAGE.read_bytes())
        self.assertEqual(png_header(APP_IMAGE)[:2], (vietqr.IMAGE_SIZE, vietqr.IMAGE_SIZE))

    def test_app_and_website_show_the_details_the_code_pays(self):
        # S8: bank name and account number in text next to the code, the same in the app and on the website.
        services = (REPO / "Packages" / "AppCore" / "Sources" / "ShellCore" / "Services.swift").read_text()
        self.assertIn(f'bankName: "{vietqr.BANK_NAME}", accountNumber: "{vietqr.ACCOUNT}"', services)
        for lang in ("vi", "en"):
            with self.subTest(lang=lang):
                pages = (REPO / "site" / "content" / lang / "pages.mjs").read_text(encoding="utf-8")
                donate = pages.split("export const donate = {", 1)[1].split("};", 1)[0]
                self.assertIn(f'bank: "{vietqr.BANK_NAME}"', donate)
                self.assertIn(f'account: "{vietqr.ACCOUNT}"', donate)
                self.assertNotIn("momo", donate.lower())

    def test_default_outputs_are_the_committed_files(self):
        self.assertEqual(set(vietqr.OUTPUTS), {APP_IMAGE, SITE_IMAGE})

    @unittest.skipUnless(importlib.util.find_spec("cv2"), "OpenCV is not installed")
    def test_committed_image_decodes_to_the_payload(self):
        self.assertEqual(vietqr.decode(APP_IMAGE), expected_payload(vietqr.default_purpose()))


if __name__ == "__main__":
    unittest.main(verbosity=1)
