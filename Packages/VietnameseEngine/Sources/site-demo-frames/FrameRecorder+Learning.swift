// SPDX-License-Identifier: MPL-2.0
//
// The learning demo of the home page (website redesign design, section 9 item 4): the teaching keys are typed
// `teach` times, each pass in a fresh field, and the collision signals of each pass are counted in
// ReferenceCollisionMemory, the reference model of the learned memory that the app's store must agree with
// (ENG-R863). Between passes the engine is rebuilt with the memory's new snapshot, as the host does (ENG-R865); the
// demo's keys are then typed with the final memory. The recording fails unless every pass corrects (a strong signal),
// gives its expected text, and the final pass commits a word by rule L9c, so the page never claims a learning the
// engine did not do.

import VietnameseEngine
import VietnameseEngineTesting

extension FrameRecorder {
    /// Records the teaching passes of `demo`, then its keys with what they taught.
    func recordLearning(
        _ demo: DemoScript.Demo, _ teaching: DemoScript.Teaching, settings: Settings
    ) throws -> RecordedDemo {
        guard teaching.passes >= 1 else { throw Failure("\(demo.id): teach must be at least 1") }
        var memory = ReferenceCollisionMemory()
        var passes: [RecordedDemo.TeachingPass] = []
        for number in 1...teaching.passes {
            let typed = try type(teaching.keys, engine: engine(settings, memory), settings: settings, demo: demo.id)
            let label = "\(demo.id): teaching pass \(number)"
            guard typed.text == teaching.expect else {
                throw Failure(
                    "\(label): expected \(String(reflecting: teaching.expect)), the engine gives "
                        + "\(String(reflecting: typed.text)); change the sentence, never the frames")
            }
            guard typed.signals.contains(where: { $0.strength == .strong }) else {
                throw Failure(
                    "\(label) gives no strong collision signal (ENG-R863): the restore toggle must correct a word "
                        + "of the collision list, or the pass teaches nothing")
            }
            memory = memory.recording(typed.signals)
            passes.append(RecordedDemo.TeachingPass(text: typed.text, frames: typed.frames, signals: typed.signals))
        }
        let typed = try type(demo.keys, engine: engine(settings, memory), settings: settings, demo: demo.id)
        guard typed.frames.contains(where: { $0.commit?.rule == CommitRule.learned.name }) else {
            throw Failure(
                "\(demo.id): after \(teaching.passes) teaching passes no commit of the final pass is decided by rule "
                    + "learned (L9c, ENG-R863); the page would claim a learning the engine did not do")
        }
        return RecordedDemo(
            id: demo.id, keys: demo.keys, method: demo.method, toneStyle: demo.toneStyle, text: typed.text,
            frames: typed.frames, teachKeys: teaching.keys, teachPasses: passes)
    }

    /// A demo engine with `memory`'s snapshot in its resources, as the host builds one after the learned memory
    /// changed (ENG-R865); otherwise the bundled resources of every demo.
    private func engine(_ settings: Settings, _ memory: ReferenceCollisionMemory) -> Engine {
        var taught = resources
        taught.collisionMemory = memory.snapshot
        return Engine(configuration: Self.configuration(settings), resources: taught)
    }
}
