// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine
public import VietnameseEngineTesting

/// The fuzz target: one input is a configuration byte followed by events in the byte encoding of
/// `FuzzAlphabet` (a printable ASCII byte is that key, BS and DEL are Backspace, ESC is the restore toggle,
/// other control bytes are resets and keypad digits, bytes from 0x80 non-ASCII letters), so seed files are
/// readable text. Every event is checked by the invariant checker of 13.6 (ENG-T30 to ENG-T37).
///
/// Configuration byte: bit 0 VNI, bit 1 standalone `w` off, bit 2 bracket keys on, bit 3 modern tone style,
/// bit 4 auto restore off, bit 5 app context `code`, bit 6 the random 1,000-trigger macro table, bit 7 history
/// limit 1 (else 16). Resources: the 13.9 fixtures. `@` (0x40) is Telex with defaults and macros, `A` VNI.
public enum FuzzTarget {
    /// One engine per configuration byte, built once (the fixture resources are shared, copy on write).
    static let engines: [Engine] = {
        let macros = (try? RandomMacroTable.table()) ?? .empty
        let plain = SpecFixtures.commitResources()
        let withMacros = SpecFixtures.commitResources(macros: macros)
        return (0..<256).map { header in
            Engine(configuration: configuration(header), resources: header & 0x40 != 0 ? withMacros : plain)
        }
    }()

    /// The engine configuration of a header byte.
    public static func configuration(_ header: Int) -> EngineConfiguration {
        let method: InputMethod =
            header & 0x01 != 0
            ? .vni : .telex(TelexOptions(standaloneW: header & 0x02 == 0, bracketKeys: header & 0x04 != 0))
        return EngineConfiguration(
            inputMethod: method, toneStyle: header & 0x08 != 0 ? .modern : .traditional,
            autoRestore: header & 0x10 == 0, appContext: header & 0x20 != 0 ? .code : .general,
            historyLimit: header & 0x80 != 0 ? 1 : 16)
    }

    /// Runs one input; returns the first broken invariant, nil when every event passes.
    public static func run(_ bytes: some Collection<UInt8>) -> FuzzViolation? {
        guard let header = bytes.first else { return nil }
        var options = InvariantChecker.Options()
        // libFuzzer's -timeout detects hangs; wall-clock checks inside one input would only add noise.
        options.hangThresholdNanoseconds = .max
        var checker = InvariantChecker(engine: engines[Int(header)], options: options)
        do {
            try checker.send(FuzzAlphabet.events(forBytes: bytes.dropFirst()))
            try checker.finish()
            return nil
        } catch let violation as FuzzViolation {
            return violation
        } catch {
            return FuzzViolation(invariant: "harness", detail: "\(error)", eventIndex: 0, recentEvents: [])
        }
    }
}
