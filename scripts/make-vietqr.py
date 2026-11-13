#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: LicenseRef-App-Pending
"""Generates the donation VietQR image (PRD-R59; Pa's decision S8 of 2026-11-13: a bank VietQR only, no MoMo).

The payload is an EMVCo merchant-presented QR code as NAPAS profiles it for VietQR transfers to an account:
  00 payload format "01"; 01 point of initiation "11" (static: the payer types the amount);
  38 merchant account: 00 NAPAS GUID A000000727, 01 beneficiary (00 acquirer BIN, 01 account number),
     02 service code QRIBFTTA (transfer to an account);
  53 currency 704 (VND); 58 country VN; 62 additional data, 08 purpose of the transfer;
  63 CRC-16/CCITT-FALSE (polynomial 0x1021, initial value 0xFFFF) over everything before it, including "6304".
The payload carries no account holder name: the payer's bank app looks the name up after the scan and shows it
before the transfer is confirmed, so no screen of the app or the website needs to show it.

The image is the QR code with error correction H and the keycap from assets/keyvi_logo.png in the centre on a
light plate (about 6 % of the modules), then decoded again with OpenCV when it is installed.

Usage:
  python3 -I scripts/make-vietqr.py --print-payload            (standard library only)
  uv run --with pillow --with qrcode --with opencv-python-headless python -I scripts/make-vietqr.py
Without --out, the image is written to the app's DonationVietQR image set and to the website's
site/static/assets/qr/vietqr.png (the same file in both places).
"""
from __future__ import annotations

import argparse
import re
import sys
import unicodedata
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BRAND_ENV = REPO_ROOT / "scripts" / "brand.env"
LOGO = REPO_ROOT / "assets" / "keyvi_logo.png"
OUTPUTS = (
    REPO_ROOT / "App" / "Resources" / "Donation.xcassets" / "DonationVietQR.imageset" / "vietqr.png",
    REPO_ROOT / "site" / "static" / "assets" / "qr" / "vietqr.png",
)

# Pa's account (S8): LioBank, an OCB digital bank, reached through OCB's NAPAS BIN. BANK_NAME is not in the
# payload; the app (DonationInfo.standard) and the website show it, and scripts/tests checks that they agree.
BANK_BIN = "970448"
ACCOUNT = "688688678"
BANK_NAME = "LioBank"
NAPAS_GUID = "A000000727"
SERVICE_TRANSFER_TO_ACCOUNT = "QRIBFTTA"
PURPOSE_MAX = 25  # EMVCo limit for the additional data sub-fields
IMAGE_SIZE = 1024
LOGO_SHARE = 0.20  # logo side as a share of the image side; error correction H restores the covered modules
LOGO_CROP = (0.21, 0.79)  # the keycap inside assets/keyvi_logo.png, as shares of the artwork's side
PLATE_FILL = (240, 239, 236, 255)


def tlv(tag: str, value: str) -> str:
    """One EMVCo data object: two-digit tag, two-digit length, value."""
    if not re.fullmatch(r"\d\d", tag):
        raise ValueError(f"tag must be two digits: {tag!r}")
    if len(value) > 99:
        raise ValueError(f"value of tag {tag} is longer than 99 characters")
    return f"{tag}{len(value):02d}{value}"


def parse_tlv(text: str) -> list[tuple[str, str]]:
    """Splits a run of data objects; raises ValueError when a length runs past the end."""
    objects, index = [], 0
    while index < len(text):
        tag, length = text[index:index + 2], text[index + 2:index + 4]
        if not (re.fullmatch(r"\d\d", tag) and re.fullmatch(r"\d\d", length)):
            raise ValueError(f"malformed data object at offset {index}")
        end = index + 4 + int(length)
        if end > len(text):
            raise ValueError(f"tag {tag} runs past the end of the payload")
        objects.append((tag, text[index + 4:end]))
        index = end
    return objects


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc


def ascii_text(text: str) -> str:
    """Vietnamese text without diacritics (bank apps show the purpose as plain ASCII)."""
    folded = unicodedata.normalize("NFD", text.replace("đ", "d").replace("Đ", "D"))
    plain = "".join(ch for ch in folded if not unicodedata.combining(ch))
    if not all(" " <= ch <= "~" for ch in plain):
        raise ValueError(f"purpose must be printable ASCII after removing diacritics: {plain!r}")
    return plain


def display_name(env_file: Path = BRAND_ENV) -> str:
    for line in env_file.read_text(encoding="utf-8").splitlines():
        match = re.match(r'^\s*APP_DISPLAY_NAME="?(.*?)"?\s*$', line)
        if match:
            return match.group(1)
    raise ValueError(f"APP_DISPLAY_NAME missing in {env_file}")


def default_purpose(env_file: Path = BRAND_ENV) -> str:
    return f"Ung ho {ascii_text(display_name(env_file))}"


def vietqr_payload(bank_bin: str, account: str, purpose: str) -> str:
    if not re.fullmatch(r"\d{6}", bank_bin):
        raise ValueError(f"bank BIN must be six digits: {bank_bin!r}")
    if not re.fullmatch(r"[0-9A-Za-z]{1,19}", account):
        raise ValueError(f"account must be 1 to 19 letters or digits: {account!r}")
    purpose = ascii_text(purpose)
    if not 0 < len(purpose) <= PURPOSE_MAX:
        raise ValueError(f"purpose must be 1 to {PURPOSE_MAX} characters: {purpose!r}")
    beneficiary = tlv("00", bank_bin) + tlv("01", account)
    merchant = tlv("00", NAPAS_GUID) + tlv("01", beneficiary) + tlv("02", SERVICE_TRANSFER_TO_ACCOUNT)
    body = (tlv("00", "01") + tlv("01", "11") + tlv("38", merchant) + tlv("53", "704") + tlv("58", "VN")
            + tlv("62", tlv("08", purpose)) + "6304")
    return body + f"{crc16_ccitt_false(body.encode('ascii')):04X}"


def crc_is_valid(payload: str) -> bool:
    body, crc = payload[:-4], payload[-4:]
    return body.endswith("6304") and f"{crc16_ccitt_false(body.encode('ascii')):04X}" == crc


def _imaging():
    try:
        import qrcode
        from PIL import Image, ImageDraw
        from qrcode.constants import ERROR_CORRECT_H
    except ImportError:
        sys.exit("error: rendering needs Pillow and qrcode, for example: uv run --with pillow --with qrcode "
                 "--with opencv-python-headless python -I scripts/make-vietqr.py")
    return qrcode, ERROR_CORRECT_H, Image, ImageDraw


def _logo_plate(logo_path: Path, size: int):
    _, _, Image, ImageDraw = _imaging()
    logo_side, pad = int(size * LOGO_SHARE), int(size * 0.018)
    source = Image.open(logo_path).convert("RGBA")
    width, height = source.size
    low, high = LOGO_CROP
    keycap = source.crop((int(width * low), int(height * low), int(width * high), int(height * high)))
    logo = keycap.resize((logo_side, logo_side), Image.LANCZOS)
    plate_side = logo_side + 2 * pad
    plate = Image.new("RGBA", (plate_side, plate_side), (0, 0, 0, 0))
    ImageDraw.Draw(plate).rounded_rectangle(
        [0, 0, plate_side - 1, plate_side - 1], radius=pad * 2, fill=PLATE_FILL)
    plate.alpha_composite(logo, (pad, pad))
    return plate


def render(payload: str, logo_path: Path, out_path: Path, size: int = IMAGE_SIZE) -> None:
    qrcode, error_correct_h, Image, _ = _imaging()
    code = qrcode.QRCode(error_correction=error_correct_h, box_size=10, border=4)
    code.add_data(payload)
    code.make(fit=True)
    image = code.make_image(fill_color="black", back_color="white").convert("RGB")
    image = image.resize((size, size), Image.NEAREST)
    plate = _logo_plate(logo_path, size)
    origin = ((size - plate.width) // 2, (size - plate.height) // 2)
    image.paste(plate, origin, plate)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    image.save(out_path, optimize=True)


def decode(path: Path) -> str | None:
    """The payload read back from the image, or None when OpenCV is not installed."""
    try:
        import cv2
    except ImportError:
        return None
    data, _, _ = cv2.QRCodeDetector().detectAndDecode(cv2.imread(str(path)))
    return data


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Generate the donation VietQR image (PRD-R59).")
    parser.add_argument("--bin", default=BANK_BIN, help=f"NAPAS acquirer BIN (default {BANK_BIN})")
    parser.add_argument("--account", default=ACCOUNT, help=f"account number (default {ACCOUNT})")
    parser.add_argument("--purpose", default=None, help='transfer purpose (default "Ung ho <display name>")')
    parser.add_argument("--logo", type=Path, default=LOGO, help="artwork for the centre logo")
    parser.add_argument("--out", type=Path, action="append", help="output PNG (repeatable)")
    parser.add_argument("--print-payload", action="store_true", help="print the payload and exit")
    args = parser.parse_args(argv)
    try:
        payload = vietqr_payload(args.bin, args.account, args.purpose or default_purpose())
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(payload)
    if args.print_payload:
        return 0
    for out in args.out or OUTPUTS:
        render(payload, args.logo, out)
        decoded = decode(out)
        if decoded is None:
            print(f"wrote {out} (not decoded: OpenCV is not installed)")
        elif decoded != payload:
            print(f"error: {out} decodes to {decoded!r}, not the payload", file=sys.stderr)
            return 1
        else:
            print(f"wrote {out} (decoded and verified)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
