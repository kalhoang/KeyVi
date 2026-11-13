// SPDX-License-Identifier: MPL-2.0
//
// Entry points of the engine fuzzer (QA-R8, QA-R9). With `-DLIBFUZZER` (Linux, `-sanitize=fuzzer`) libFuzzer
// provides `main` and calls `LLVMFuzzerTestOneInput`; without it this file's `main` replays the seed corpus
// and runs seeded random mutations, so the harness builds and runs on macOS too, where the Xcode toolchain
// has no libFuzzer runtime for Swift.

import EngineFuzzTarget
import Foundation
import VietnameseEngineTesting

/// `ENGINE_FUZZ_METHOD=telex` or `vni` pins bit 0 of the configuration byte, for the nightly runs of 30
/// minutes per method (QA-R8).
let pinnedMethod: UInt8? = {
    switch ProcessInfo.processInfo.environment["ENGINE_FUZZ_METHOD"] {
    case "telex": return 0
    case "vni": return 1
    default: return nil
    }
}()

/// libFuzzer entry point: a broken invariant aborts, so libFuzzer saves and minimises the input.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ data: UnsafePointer<UInt8>?, _ size: Int) -> CInt {
    guard let data, size > 0 else { return 0 }
    var bytes = Array(UnsafeBufferPointer(start: data, count: size))
    if let pinnedMethod { bytes[0] = (bytes[0] & 0xFE) | pinnedMethod }
    if let violation = FuzzTarget.run(bytes) {
        fatalError("\(violation)")
    }
    return 0
}

#if !LIBFUZZER
@main
struct ReplayDriver {
    /// `engine-fuzz [--mutations N] [--seed S] PATH...`: replays every file (directories are walked) and
    /// then, for each, N seeded mutations (byte flips, insertions, deletions, splices). Exit status 1 on
    /// the first broken invariant, with the input written next to the working directory.
    static func main() throws {
        var mutations = 0
        var seed: UInt64 = 1
        var paths: [String] = []
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--mutations": mutations = arguments.next().flatMap(Int.init) ?? 0
            case "--seed": seed = arguments.next().flatMap(UInt64.init) ?? 1
            default: paths.append(argument)
            }
        }
        let inputs = try files(paths).map { (name: $0, bytes: [UInt8](try Data(contentsOf: URL(fileURLWithPath: $0)))) }
        var generator = SeededGenerator(seed: seed)
        var count = 0
        for input in inputs {
            try check(input.bytes, name: input.name)
            count += 1
            for _ in 0..<mutations {
                let other = generator.pick(inputs).bytes
                try check(mutate(input.bytes, splicing: other, using: &generator), name: "\(input.name) (mutation)")
                count += 1
            }
        }
        print("engine-fuzz: \(count) inputs, \(inputs.count) seed files, no invariant broken")
    }

    static func check(_ bytes: [UInt8], name: String) throws {
        guard let violation = FuzzTarget.run(bytes) else { return }
        let path = "engine-fuzz-failure.bin"
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        print("engine-fuzz: \(name): \(violation)\ninput written to \(path)")
        exit(1)
    }

    static func files(_ paths: [String]) throws -> [String] {
        var result: [String] = []
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let names = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
                result += names.filter { !$0.hasPrefix(".") }.map { "\(path)/\($0)" }
            } else {
                result.append(path)
            }
        }
        return result
    }

    static func mutate(_ bytes: [UInt8], splicing other: [UInt8], using generator: inout SeededGenerator) -> [UInt8] {
        var result = bytes
        for _ in 0...generator.nextInt(below: 8) {
            let position = result.isEmpty ? 0 : 1 + generator.nextInt(below: max(1, result.count - 1))
            switch generator.nextInt(below: 4) {
            case 0 where position < result.count: result[position] = UInt8(truncatingIfNeeded: generator.next())
            case 1: result.insert(UInt8(truncatingIfNeeded: generator.next()), at: min(position, result.count))
            case 2 where position < result.count: result.remove(at: position)
            default:
                let start = generator.nextInt(below: max(1, other.count))
                let slice = other.dropFirst(start).prefix(1 + generator.nextInt(below: 64))
                result.insert(contentsOf: slice, at: min(position, result.count))
            }
        }
        return result
    }
}
#endif
