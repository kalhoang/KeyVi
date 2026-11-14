# VietnameseEngineFuzz

Coverage-guided fuzzing of the engine (spec/04-quality-release.md QA-R8, QA-R9; spec/01-engine.md 13.6,
ENG-T30 to ENG-T37). A separate package with a path dependency on `../VietnameseEngine`, so the engine
package itself never links libFuzzer.

Licence: Mozilla Public License 2.0, like the engine (`LICENSE`, the verbatim text; the copyright line and the
MPL-2.0 Exhibit A notice are in `NOTICE`).

## Input format

One input is a configuration byte followed by events. The configuration byte selects the method and the
options (bit 0 VNI, bit 1 standalone `w` off, bit 2 bracket keys on, bit 3 modern tone style, bit 4 auto
restore off, bit 5 app context `code`, bit 6 the random 1,000-trigger macro table, bit 7 history limit 1);
`@` is Telex with defaults and macros, `A` is VNI with macros. Every following byte is one event in the
encoding of `FuzzAlphabet` (VietnameseEngineTesting): a printable ASCII byte is that key, `\n` `\r` `\t` are
Return and Tab, BS and DEL are Backspace, ESC is the restore toggle, the other control bytes are the twelve
reset reasons and keypad digits, and bytes from 0x80 are non-ASCII letters and spaces. Seed files are
therefore mostly readable text. Each event is checked by `InvariantChecker` (simulated field, exact
restore, replay, encoding, method isolation, escape, viability, bounded history); a broken invariant aborts
with a report of the last events in corpus notation.

## Linux CI (libFuzzer)

The Linux Swift toolchain ships libFuzzer. Pull requests (60 seconds) and nightly runs:

```sh
cd Packages/VietnameseEngineFuzz
swift build -c release --product engine-fuzz \
  -Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library -Xswiftc -DLIBFUZZER
mkdir -p .fuzz-corpus
# Pull request: 60 s; new inputs go to .fuzz-corpus, the committed seeds in Corpus/ are read only.
.build/release/engine-fuzz .fuzz-corpus Corpus -max_len=8192 -timeout=10 -max_total_time=60 -print_final_stats=1
# Nightly: 30 minutes per method (QA-R8), AddressSanitizer as above; repeat with
# -Xswiftc -sanitize=fuzzer,undefined for UndefinedBehaviorSanitizer (VERIFY that the toolchain accepts it).
ENGINE_FUZZ_METHOD=telex .build/release/engine-fuzz .fuzz-corpus Corpus -max_len=8192 -timeout=10 -max_total_time=1800
ENGINE_FUZZ_METHOD=vni   .build/release/engine-fuzz .fuzz-corpus Corpus -max_len=8192 -timeout=10 -max_total_time=1800
```

A crash leaves `crash-<hash>` in the working directory; replay it with `.build/release/engine-fuzz crash-<hash>`,
minimise it with `-minimize_crash=1 -runs=100000`, add the minimised keys to
`Packages/VietnameseEngine/Tests/VietnameseEngineTests/Corpus/crash-regressions.tsv` when fixed (QA-R8), and
the input itself to `Corpus/`.

Monthly minimisation of the seed corpus (QA-R9):

```sh
mkdir Corpus.min && .build/release/engine-fuzz -merge=1 Corpus.min Corpus .fuzz-corpus && rm -r Corpus && mv Corpus.min Corpus
```

VERIFY on the Linux runner: the flags above follow the Swift toolchain's libFuzzer support
(`-sanitize=fuzzer` with `-parse-as-library`); this package could not be built with libFuzzer on the
development Mac.

## macOS

The Xcode toolchain has no libFuzzer runtime for Swift (`swiftc -sanitize=fuzzer` fails with "unsupported
option '-sanitize=fuzzer' for target 'arm64-apple-macosx'"). Without `-DLIBFUZZER` the same executable has
a `main` that replays files and runs seeded random mutations (byte flips, insertions, deletions, splices):

```sh
swift test                                                # replays the seed corpus (SeedCorpusTests)
swift build -c release --product engine-fuzz
.build/release/engine-fuzz --mutations 300 --seed 1 Corpus   # 4,816 inputs in about 16 s on an M4
```

`swift build -Xswiftc -DLIBFUZZER --scratch-path .build-libfuzzer` type-checks the libFuzzer entry point on
macOS and stops at the link step (no `main`, which libFuzzer provides on Linux).
