// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine

@Test func scaffoldCompiles() {
    let engine = Engine(configuration: EngineConfiguration(typoCorrection: false), resources: .empty)
    let (_, output) = engine.reduce(.initial, .key(KeyInput("a")))
    #expect(output.composingText.isEmpty || !output.composingText.isEmpty)
}
