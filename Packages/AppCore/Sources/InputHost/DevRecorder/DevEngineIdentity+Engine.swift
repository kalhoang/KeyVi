// SPDX-License-Identifier: GPL-3.0-or-later
//
// The app's side of the dev trace's engine identity (PLT-R904A, ADR 0007 decision 13): the bundled engine with the
// default configuration and no user word lists, fed the probes of `DevEngineIdentity`. The scanner computes the same
// digest with its own engine (TraceScanCore `ReplayEngineFactory.identity`); TestSupport pins that the two agree.

public import Diagnostics
internal import VietnameseEngine
internal import VietnameseEngineData

extension DevEngineIdentity {
    /// The identity of the engine this binary links, or nil when the bundled word lists do not load.
    public static func ofLinkedEngine() -> String? {
        guard let resources = try? Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([])) else {
            return nil
        }
        return digest { vni in
            let method: InputMethod = vni ? .vni : .telex(TelexOptions())
            var session = Session(
                engine: Engine(configuration: EngineConfiguration(inputMethod: method), resources: resources))
            return { character in
                switch session.handle(.key(KeyInput(character))).action {
                case .passThrough: .passThrough
                case .edit(let edit, let thenPassThrough):
                    .edit(deleteCount: edit.deleteCount, insert: edit.insert, thenPassThrough: thenPassThrough)
                }
            }
        }
    }
}
