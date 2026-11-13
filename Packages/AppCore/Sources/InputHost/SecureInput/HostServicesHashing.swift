// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hashes used by host services: SHA-256 for executable keys (PLT-R393) and signing-identity digests
// (PLT-R720), and a short stable hash that survives key-value stores holding integers as doubles.

import CryptoKit
import Foundation

enum HostServicesHashing {
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }.joined()
    }

    /// FNV-1a 64 folded to 52 bits and never zero (zero means "absent" in `KeyValueStore`). 52 bits keep the
    /// value exact when a store keeps integers as `Double`.
    static func stableHash52(_ text: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let folded = (hash ^ (hash >> 52)) & ((1 << 52) - 1)
        return Int(folded == 0 ? 1 : folded)
    }
}
