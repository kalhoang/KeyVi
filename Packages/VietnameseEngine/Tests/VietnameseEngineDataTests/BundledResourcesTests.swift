// SPDX-License-Identifier: MPL-2.0
//
// The bundled resources load, contain what spec/01-engine.md 8.2 promises and stay inside the
// ENG-R1231 budget (50 ms, 8 MB). Serialized so that the memory measurement is not disturbed by
// another test of this suite loading the same data at the same time.

import Foundation
import Testing
import VietnameseEngineData

@testable import VietnameseEngine

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
        // The capitalized code-word list (8.2, ENG-R850 as amended on 16/11/2026): v1 holds `host` only, a
        // code-only word (`Host github.com` in ~/.ssh/config, `Host: example.com`).
        let capitalizedFile = TestPaths.committedResources.appendingPathComponent("tech-code-capitalized.txt")
        let capitalized = try String(contentsOf: capitalizedFile, encoding: .utf8)
        #expect(capitalized == "host\n" && resources.techCodeCapitalized.contains("host"))
        #expect(resources.techCodeOnly.contains("host"))
        #expect(!resources.techCodeCapitalized.contains("tar") && !resources.techCodeCapitalized.contains("tee"))
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

    /// ENG-R1118: the host's never-correct list reaches the engine through `bundled` and `load(from:)`, next to the
    /// correction data of ENG-R1120.
    @Test func passesTheNeverCorrectListThrough() throws {
        let resources = try Resources.bundled(
            userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]), userNeverCorrect: WordSet(["androdi"]))
        #expect(resources.userNeverCorrect.contains("androdi"))
        #expect(!resources.userKeepRaw.contains("androdi"))
        #expect(resources.correction.keyboardNeighbours.count == 26)
        let loaded = try Resources.load(
            from: TestPaths.committedResources, userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]),
            userNeverCorrect: WordSet(["gramar"]))
        #expect(loaded.userNeverCorrect.contains("gramar"))
        let withoutTheList = try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
        #expect(!withoutTheList.userNeverCorrect.contains("androdi"))
    }

    /// ENG-R1120: the five resources of the typo correction load with the bundle: the QWERTY table of ENG-R1113, the
    /// unmarked shapes, the Vietnamese keyings and the guard list (SCOWL words of sizes 40 to 70 and proper names,
    /// minus the correction lexicon; the correction lexicon itself is `english` and `techAlways`).
    @Test func loadsTheCorrectionData() throws {
        let correction = try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([])).correction
        #expect(correction.keyboardNeighbours.count == 26)
        #expect(correction.keyboardNeighbours["q"] == "wa" && correction.keyboardNeighbours["m"] == "jkn")
        for shape in ["truong", "nguoi", "khong", "thuong", "thach", "glong"] {
            #expect(correction.unmarkedShapes.contains(shape), "\(shape)")
        }
        for keying in ["phair", "phis", "chinhs", "thieeus", "hoanf", "thwowngf"] {
            #expect(correction.vietnameseKeyings.contains(keying), "\(keying)")
        }
        #expect(!correction.unmarkedShapes.contains("android") && !correction.vietnameseKeyings.contains("gamar"))
        // Spec 12.2 (sixth amendment): packed sets, every bundled word packed (none longer than twelve letters).
        #expect(correction.unmarkedShapes.count == 3_953 && correction.vietnameseKeyings.count == 27_277)
        #expect(correction.unmarkedShapes.packed.count == 3_953 && correction.vietnameseKeyings.packed.count == 27_277)
        // `Biden` is a proper name of size 50, `quixotic` a word of size 40; `android` is in the lexicon (size 35),
        // so the guard list does not hold it.
        #expect(correction.guardList.mayContain("biden") && correction.guardList.mayContain("quixotic"))
        #expect(!correction.guardList.mayContain("android"))
        #expect(correction.guardList.hashCount == 8)
        #expect(correction.guardList.bits.count * 8 <= 512 * 1024)
    }

    @Test func bundledNoticesCarryTheScowlNotice() throws {
        // ENG-R811: the app shows the SCOWL notice in its acknowledgements.
        let notices = try Resources.bundledNotices()
        #expect(notices.contains("Copyright 2000-2018 by Kevin Atkinson"))
        #expect(notices.contains("Permission to use, copy, modify, distribute and sell these word"))
        #expect(notices.contains("Article 15(2)"))
        // ENG-R811, ENG-R1120: the guard list is under the same notice as the lexicon.
        #expect(notices.contains("guard-list.bloom"))
    }

    @Test func bundledNoticesCreditTheLegalTextPortals() throws {
        // ENG-R811 and docs/decisions/0200 section 2: the download portals of the legal texts ask for
        // their name when information is republished, and THIRD_PARTY_NOTICES.md section 3 promises
        // that courtesy credit in the shipped NOTICES.txt.
        let notices = try Resources.bundledNotices()
        #expect(notices.contains("Intellectual Property Office of Viet Nam (ipvietnam.gov.vn)"))
        #expect(notices.contains("Official Gazette (congbao.chinhphu.vn)"))
    }

    /// ENG-R1231: `Resources.bundled` loads in at most 50 ms and all resources take at most 8 MB.
    /// Memory is measured as the growth of live malloc bytes while the loaded resources are held
    /// (page-level footprint is useless here: earlier loads leave reusable pages behind), repeated
    /// five times; the median is compared with the budget.
    ///
    /// Time: this debug test shares the machine with the parallel test suites, which stretches wall time
    /// with waiting, not with loading. It asserts the median CPU time of the loading thread, which waiting
    /// does not count, and a loose median wall-time guard (twice the budget) so that a real slowdown still
    /// fails this unit test. The fastest wall time is printed only: on a shared machine even the fastest of
    /// five loads exceeded 50 ms (51.4 ms with 25.8 ms of CPU time). The normative gate is the release
    /// benchmark (`engine-benchmark`, `Benchmarks/compare.py`), which asserts the cold wall-clock load
    /// against the 50 ms budget.
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
