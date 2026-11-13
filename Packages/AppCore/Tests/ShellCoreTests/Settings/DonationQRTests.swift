// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R59 and Pa's decision S8: the bundled VietQR code pays the account the donation block shows. The image is
// decoded with Core Image and its EMVCo payload checked field by field (NAPAS profile, CRC-16/CCITT-FALSE), so a
// regenerated or replaced image that pays another account, names the holder or breaks the checksum fails here.

import CoreImage
import Foundation
import Testing

@testable import ShellCore

@Suite struct DonationQRTests {
    /// EMVCo data objects: two-digit tag, two-digit length, value.
    static func objects(_ text: String) throws -> [(tag: String, value: String)] {
        var result: [(tag: String, value: String)] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            let tag = String(rest.prefix(2))
            let length = try #require(Int(rest.dropFirst(2).prefix(2)), "malformed length after tag \(tag)")
            let body = rest.dropFirst(4)
            try #require(body.count >= length, "tag \(tag) runs past the end")
            result.append((tag, String(body.prefix(length))))
            rest = body.dropFirst(length)
        }
        return result
    }

    static func value(_ tag: String, in objects: [(tag: String, value: String)]) -> String? {
        objects.first { $0.tag == tag }?.value
    }

    /// CRC-16/CCITT-FALSE: polynomial 0x1021, initial value 0xFFFF, no reflection, no final XOR.
    static func crc(_ text: String) -> String {
        var crc: UInt16 = 0xFFFF
        for byte in text.utf8 {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return String(format: "%04X", crc)
    }

    static func imageURL() throws -> URL {
        let folder = RepoPaths.url("App/Resources/Donation.xcassets/\(DonationInfo.standard.vietQRImageName).imageset")
        let data = try Data(contentsOf: folder.appendingPathComponent("Contents.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let images = try #require(json["images"] as? [[String: Any]])
        let file = try #require(images.first?["filename"] as? String)
        return folder.appendingPathComponent(file)
    }

    static func decodedPayload() throws -> String {
        let image = try #require(CIImage(contentsOf: try imageURL()))
        let detector = try #require(
            CIDetector(
                ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let codes = detector.features(in: image).compactMap { $0 as? CIQRCodeFeature }
        #expect(codes.count == 1)
        return try #require(codes.first?.messageString)
    }

    @Test func checksumMatchesTheStandardCheckValue() {
        #expect(Self.crc("123456789") == "29B1")
    }

    @Test func bundledCodePaysTheAccountTheBlockShows_PRDR59() throws {
        let payload = try Self.decodedPayload()
        let top = try Self.objects(payload)
        #expect(top.map(\.tag) == ["00", "01", "38", "53", "58", "62", "63"])
        #expect(Self.value("00", in: top) == "01")
        #expect(Self.value("01", in: top) == "11", "static code: the payer types the amount")
        #expect(Self.value("53", in: top) == "704")
        #expect(Self.value("58", in: top) == "VN")
        let merchant = try Self.objects(try #require(Self.value("38", in: top)))
        #expect(Self.value("00", in: merchant) == "A000000727")
        #expect(Self.value("02", in: merchant) == "QRIBFTTA", "transfer to an account")
        let beneficiary = try Self.objects(try #require(Self.value("01", in: merchant)))
        #expect(Self.value("00", in: beneficiary) == "970448", "LioBank through the OCB NAPAS BIN")
        #expect(Self.value("01", in: beneficiary) == DonationInfo.standard.accountNumber)
        #expect(Self.crc(String(payload.dropLast(4))) == String(payload.suffix(4)))
    }

    @Test func payloadNamesTheAppButNeverTheAccountHolder_PRDR59() throws {
        let top = try Self.objects(try Self.decodedPayload())
        // S8: no merchant name (59) or city (60); the bank app shows the holder after the scan.
        #expect(!top.contains { $0.tag == "59" || $0.tag == "60" })
        let additional = try Self.objects(try #require(Self.value("62", in: top)))
        let brand = try BrandFiles.values().displayName
        let plain = brand.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
            .folding(options: .diacriticInsensitive, locale: nil)
        #expect(Self.value("08", in: additional) == "Ung ho \(plain)")
    }

    @Test func websiteServesTheSameImage() throws {
        let app = try Data(contentsOf: try Self.imageURL())
        let site = try Data(contentsOf: RepoPaths.url("site/static/assets/qr/vietqr.png"))
        #expect(app == site)
    }
}
