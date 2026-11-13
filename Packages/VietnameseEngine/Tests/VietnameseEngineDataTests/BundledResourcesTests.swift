// SPDX-License-Identifier: MPL-2.0
//
// The bundled resources load, contain what spec/01-engine.md 8.2 promises and stay inside the
// ENG-R1231 budget (50 ms, 8 MB). Serialized so that the memory measurement is not disturbed by
// another test of this suite loading the same data at the same time.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineData

#if canImport(Darwin)
import Darwin
#endif

@Suite(.serialized)
struct BundledResourcesTests {
    @Test func loadsAndContainsTheSpecifiedData() throws {
        let resources = try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
        // English lexicon: SCOWL words, lowercase ASCII (ENG-T12 spot words that are dictionary words).
        for word in [
            "text", "user", "case", "data", "password", "traffic", "boss", "coffee", "tomorrow", "mother", "the", "and",
            "you",
        ] {
            #expect(resources.english.contains(word), "english lexicon lacks \(word)")
        }
        #expect(!resources.english.contains("Monday"))
        // Tech lists (spec/01-engine.md 8.2 examples).
        for word in [
            "www", "http", "https", "wifi", "usb", "ios", "macos", "json", "html", "api", "url", "a4", "mp3", "mp4",
            "4g", "5g", "h2o",
        ] {
            #expect(resources.techAlways.contains(word), "tech-always lacks \(word)")
        }
        for word in ["tar", "less", "more", "cat", "top", "make", "sed", "awk"] {
            #expect(resources.techCodeOnly.contains(word), "tech-code-only lacks \(word)")
        }
        // Words whose Telex typing is a common Vietnamese syllable must not be tech-always (L11).
        for word in ["gif", "uri", "rar"] { #expect(!resources.techAlways.contains(word)) }
        // Attested additions and both tone styles of open oa/oe/uy (5.2).
        for syllable in ["á", "há", "ít", "thí", "thế", "thể", "bên", "cả", "đi", "thêm", "mã", "ú"] {
            #expect(resources.attestedSyllables.contains(syllable), "attested lacks \(syllable)")
        }
        // Ambiguity proposals of ENG-R821; unreviewed rows behave as vi.
        #expect(resources.ambiguity["as"] == .vietnamese)
        #expect(resources.ambiguity["is"] == .english)
        #expect(resources.ambiguity["test"] == .english)
        #expect(resources.ambiguity["max"] == .vietnamese)
        #expect(resources.ambiguity["us"] == .vietnamese)
        #expect(resources.ambiguity["facebook"] == nil)
    }

    @Test func passesUserListsAndMacrosThrough() throws {
        let macros = try MacroTable([.init(trigger: "vn", expansion: "Việt Nam")])
        let resources = try Resources.bundled(
            userKeepRaw: WordSet(["abc"]), userKeepVietnamese: WordSet(["thoi"]), macros: macros)
        #expect(resources.userKeepRaw.contains("abc"))
        #expect(resources.userKeepVietnamese.contains("thoi"))
        #expect(!resources.userKeepRaw.contains("thoi"))
    }

    @Test func bundledNoticesCarryTheScowlNotice() throws {
        // ENG-R811: the app shows the SCOWL notice in its acknowledgements.
        let notices = try Resources.bundledNotices()
        #expect(notices.contains("Copyright 2000-2018 by Kevin Atkinson"))
        #expect(notices.contains("Permission to use, copy, modify, distribute and sell these word"))
        #expect(notices.contains("Article 15(2)"))
    }

    /// ENG-R1231: `Resources.bundled` loads in at most 50 ms and all resources take at most 8 MB.
    /// Memory is measured as the growth of live malloc bytes while the loaded resources are held
    /// (page-level footprint is useless here: earlier loads leave reusable pages behind), repeated
    /// five times; the median is compared with the budget.
    ///
    /// Time: this debug test shares the machine with the parallel test suites, which stretches wall time
    /// with waiting, not with loading. It asserts the median CPU time of the loading thread, which waiting
    /// does not count, the fastest wall time, which shows the load fits when the thread runs, and a loose
    /// median wall-time guard (twice the budget) so that a real slowdown still fails this unit test. The
    /// normative gate is the release benchmark (`engine-benchmark`, `Benchmarks/compare.py`), which asserts
    /// the cold wall-clock load against the 50 ms budget.
    @Test func staysWithinLoadTimeAndMemoryBudget() throws {
        let clock = ContinuousClock()
        var timings: [Duration] = []
        var cpuTimes: [Duration] = []
        var growth: [Int] = []
        var loaded: Resources?
        for _ in 0..<5 {
            loaded = nil
            let before = liveMallocBytes()
            let cpuBefore = threadCPUTime()
            timings.append(
                try clock.measure {
                    loaded = try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
                })
            cpuTimes.append(threadCPUTime() - cpuBefore)
            growth.append(liveMallocBytes() - before)
        }
        let median = timings.sorted()[timings.count / 2]
        let fastest = timings.min() ?? median
        let cpuMedian = cpuTimes.sorted()[cpuTimes.count / 2]
        let growthMB = Double(growth.sorted()[growth.count / 2]) / 1_048_576
        let estimateMB = Double(estimatedBytes(try #require(loaded))) / 1_048_576
        print(
            "ENG-R1231 measurement (debug): first load \(milliseconds(timings[0])) ms, median \(milliseconds(median)) ms, "
                + "fastest \(milliseconds(fastest)) ms, thread CPU median \(milliseconds(cpuMedian)) ms; "
                + "live heap growth (median) \(String(format: "%.2f", growthMB)) MB; "
                + "estimated retained \(String(format: "%.2f", estimateMB)) MB")
        #expect(cpuMedian < .milliseconds(50), "median CPU time of a load \(cpuMedian) exceeds 50 ms")
        #expect(fastest < .milliseconds(50), "fastest load \(fastest) exceeds 50 ms")
        #expect(median < .milliseconds(100), "median wall time of a load \(median) exceeds twice the 50 ms budget")
        #expect(growthMB <= 8, "resources hold \(growthMB) MB")
        #expect(estimateMB <= 8, "estimated retained size \(estimateMB) MB")
        withExtendedLifetime(loaded) {}
    }

    /// CPU time consumed by the calling thread (zero where the clock is unavailable).
    private func threadCPUTime() -> Duration {
        var time = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0 else { return .zero }
        return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
    }

    private func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        return String(format: "%.1f", value)
    }

    /// Lower-bound estimate of what the loaded word sets retain: Set storage (16-byte String per
    /// bucket at the default 75 % load factor) plus heap storage for strings longer than 15 UTF-8
    /// bytes (small strings live inline in the 16-byte value).
    private func estimatedBytes(_ resources: Resources) -> Int {
        let lists = try? [
            "english.txt", "tech-always.txt", "tech-code-only.txt", "attested.txt",
        ].map { name in
            try String(contentsOf: TestPaths.committedResources.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }
        var total = 0
        for words in lists ?? [] {
            var buckets = 1
            while Double(buckets) * 0.75 < Double(words.count) { buckets *= 2 }
            total += buckets * 16 + buckets / 8
            for word in words where word.utf8.count > 15 { total += 32 + (word.utf8.count + 15) / 16 * 16 }
        }
        return total + resources.ambiguity.count * 64
    }

    private func liveMallocBytes() -> Int {
        #if canImport(Darwin)
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
        #else
        return 0
        #endif
    }
}
