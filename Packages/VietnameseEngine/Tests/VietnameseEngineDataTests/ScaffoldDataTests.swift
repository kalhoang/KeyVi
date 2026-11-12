// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineData

@Test func bundledLoads() throws {
    _ = try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
}
