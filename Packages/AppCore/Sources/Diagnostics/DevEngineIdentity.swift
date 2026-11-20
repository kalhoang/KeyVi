// SPDX-License-Identifier: GPL-3.0-or-later
//
// The engine identity of a dev trace (PLT-R904A, ADR 0007 decision 13, 2026-11-15). The engine package carries no
// version, and a dev build and the scanner are often built from different commits; a trace replayed with another
// engine reports "divergences" that are only rule changes (Pa's traces of 14/11/2026: the English-run amendment of
// ENG-R823 made every replay of "cũng tricky as" diverge). The identity is a digest of what the engine produces for a
// fixed set of probes with the default configuration and the bundled word lists only: the recorder writes it in
// every file line, the scanner computes its own, and replay runs only when the two agree. Both sides feed the
// probes through `Session` and hand each output to `digest` as a `Step`, so the digest depends on engine
// behaviour, not on the build. Not compiled out of release builds: the scanner (built in release) needs it; it
// holds test inputs, never typed content.

public enum DevEngineIdentity {
    /// What one probe key did, as the host applies it to the field.
    public enum Step: Sendable, Hashable {
        case passThrough
        case edit(deleteCount: Int, insert: String, thenPassThrough: Bool)
    }

    /// Telex probes (default options): tones, marks, escapes, separators, capitals and code-switched phrases whose
    /// English restore and collision rules change most often (ENG-R8xx), and since 1.1.0 worked examples of the typo
    /// correction (13.12 rows S01, S02, S25 and S75, ENG-R1110 to ENG-R1125) and of a `w` doubled out of habit (13.9.5
    /// rows X28 and X34, ENG-R804, REG-40), so a build whose correction or escape restore differs gets another
    /// identity.
    public static let telexProbes: [String] = [
        "vieejt nam ", "dduowngf ", "tieesng vieejt ", "hoaf binhf ", "quas ", "giaf ", "khuyeen ", "nguyeenx ",
        "thuowr ", "truwowngf hojc ", "nhaajn ", "ass ", "verr ", "Saff ", "ww ", "teee ", "boss ", "mass ",
        "cungx tricky as. ", "cungx tricky as ", "tricky as hell ", "this is as good ", "Minhf nghix this is as ",
        "hello world ", "facebook ", "windows ", "class ", "return ", "string ", "test case ", "user ", "dos ",
        "VIEEJT NAM ", "Ddaf Nawngx ", "w ", "uw ", "ow ", "aw ", "dd ", "vieejt, nam. ", "ddaau? ", "khoong! ",
        "xin chaof cacs banj ", "toi ddi hocj ", "awn uoongs ", "ngoaif troiwf ", "gif ", "quoocs ", "huyeenf ",
        "androdi ", "gramar ", "androdi. ", "ddi pahir ", "wwebview ", "answwer ",
    ]

    /// VNI probes.
    public static let vniProbes: [String] = ["vie65t nam ", "d9u7o7ng2 ", "hoa2 ", "qua1 ", "tie61ng ", "a1a1 "]

    /// The digest of the text the probes produce; `makeTyper(vni)` returns a fresh session's step function for
    /// Telex (false) or VNI (true). `p<count>-<16 hex digits>` (FNV-1a, 64 bit).
    public static func digest(makeTyper: (_ vni: Bool) -> (Character) -> Step) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ byte: UInt8) { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        for (probes, vni) in [(telexProbes, false), (vniProbes, true)] {
            for probe in probes {
                for byte in type(probe, with: makeTyper(vni)).utf8 { mix(byte) }
                mix(0xFF)  // never a UTF-8 byte: separates the probes
            }
        }
        let hex = String(hash, radix: 16)
        return "p" + String(telexProbes.count + vniProbes.count) + "-"
            + String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// The field text after typing `probe` key by key, applying each step as the host does (an edit, then the key
    /// itself when the step passes it on).
    static func type(_ probe: String, with step: (Character) -> Step) -> String {
        var text: [Character] = []
        for character in probe {
            switch step(character) {
            case .passThrough:
                text.append(character)
            case .edit(let deleteCount, let insert, let thenPassThrough):
                text.removeLast(min(deleteCount, text.count))
                text.append(contentsOf: insert)
                if thenPassThrough { text.append(character) }
            }
        }
        return String(text)
    }
}
