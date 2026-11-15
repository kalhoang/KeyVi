// SPDX-License-Identifier: MPL-2.0
//
// QA-R68 (spec/04-quality-release.md) and spec/01-engine.md 13.11: the W11 collision corpus and the three
// adversarial sets run through the engine with the thresholds of ENG-R876 and ENG-R877. Workstream W11-D adds
// the fixtures and the replay harness here; until then the target only checks that the bundled collision
// lists it will need are loaded.

import Testing
import VietnameseEngine
import VietnameseEngineData

@Suite("W11 collision corpus (QA-R68)")
struct CollisionCorpusTests {
    @Test("The bundled resources carry the collision lists the corpus gate reads")
    func bundledCollisionLists() throws {
        let resources = try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
        #expect(resources.collision.phrases.count > 0)
        #expect(resources.collision.boundaryParticles.contains("as"))
        #expect(resources.collisionMemory.isEmpty)
    }
}
