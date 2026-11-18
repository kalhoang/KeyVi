# Runbook: CLR-R13 similarity review (dirty side)

Owner: the maintainer commissions it; a reviewer the maintainer appoints performs it. Specification:
[spec/05-clean-room.md](../../spec/05-clean-room.md) CLR-R13 and section 5 (acceptance). Process around it:
[provenance README](../provenance/README.md). Decision: [ADR 0009](../decisions/0009-pa-decisions-2026-11-18.md)
item 2 (the product owner, 2026-11-18).

{{AppName}} is written from scratch from `spec/`. This runbook tells an outside reviewer how to check that no code of
another Vietnamese input method reached it. It is written for the reviewer, who may read the other projects' code.
The runbook itself contains no code, file name, identifier, data layout or summary of any other input method, and it
links to none of them: it names the compared projects by public name only. Keep it that way when you edit it.

## 1. Purpose and when it runs

CLR-R13 asks for a similarity review by someone allowed to look at the other codebases, before the first public
release and before 1.0, and the acceptance of spec/05 section 5 asks for a provenance report for every public
release with no unresolved match. The record review of 1.0.0
([2026-11-17-1.0.0.md](../provenance/reports/2026-11-17-1.0.0.md)) checked the repository's own evidence; it did
not compare against other codebases (its note N1). This runbook covers that comparison.

| Run | Target | Scope |
|---|---|---|
| First run | `9d63a3607fb01a1b65116668d236162466f2a3ae`, the commit of the tag `v1.0.0` (shipped on 2026-11-18) | Full: every path of section 4 |
| Every later public release that changes engine or input-handling code | The commit to be tagged | Delta: the paths of section 4 changed since the commit of the previous similarity report (`git diff --name-only <previous> <target>`), read in the context of the whole files they belong to |
| A public release that changes none of those paths | The commit to be tagged | No comparison; the maintainer records in the release's provenance report that no path of section 4 changed since the previous similarity report |
| A contribution that looks suspicious | The pull request's head commit | Targeted: the files of that pull request |

A `fail` verdict blocks the release until section 8 is done ([release runbook](release.md) section 2). A review
that is commissioned but not finished does not block a release by itself: the release's provenance report records
that the comparison is pending, as the 1.0.0 record did (its note N1), and the next similarity report covers
everything since the last finished one. For 1.0.1 that is the first run on `9d63a360` (which already includes
`4ebe3bd9..9d63a360`, the escape rule change of rule L4 shipped in 1.0.0 after the record review) and the delta from
`9d63a360` to the commit of 1.0.1; both may go into one report.

## 2. Who may review

- Someone the maintainer appoints, who **may** look at the source code of the other input methods (the "dirty
  side").
- Someone who has **never contributed** to this repository: no commit, no pull request, no code review, no issue
  comment about engine or input-handling code, and no automated coding assistant of theirs that worked on this
  repository. After the review they do not write engine or input-handling code for the areas they compared.
- An automated assistant may help with the comparison only in a session and workspace of the reviewer that never
  touched this repository's implementation work; its output is a lead, and the reviewer confirms every finding by
  reading.

The maintainer writes the reviewer's name, the date of appointment and why they qualify into the report (section 7).

## 3. Isolation rules

Results flow one way: from the reviewer to the maintainer, as the report of section 7 and nothing else.

1. The reviewer works on their own machine, in a folder outside any clone that pushes to this repository. Clone
   this repository read-only at the target commit (`git clone` then `git checkout <commit>`); never push from that
   clone.
2. Never commit, paste, attach or upload code, file names, identifiers, data tables, comments or screenshots of
   another input method to this repository, its issues, pull requests, discussions, wiki, release notes or website,
   or to any chat or memory store the maintainers or their coding tools use.
3. Never discuss how another input method is built with the maintainers, contributors or their coding tools, not even
   to explain a finding. A finding names only {{AppName}} paths and line ranges and the kind of similarity
   (section 6).
4. The maintainers do not ask for details beyond the report. If a finding is unclear, the reviewer rewrites the
   finding's description in {{AppName}} terms; they never quote the other side.
5. Delete the working copies of the other projects and the tool output when the report is signed, or keep them
   only on the reviewer's machine, never in a shared location.

## 4. What to compare

**{{AppName}} side** (at the target commit):

| Path | What it is |
|---|---|
| `Packages/VietnameseEngine/Sources/VietnameseEngine/` | The typing engine |
| `Packages/VietnameseEngine/Sources/VietnameseEngineData/*.swift` | The engine's resource loader |
| `Packages/VietnameseEngine/Sources/lexicon-builder/` | The tool that builds the bundled word lists |
| `data/fetch.sh` and the hand-written lists of `data/inputs/` (every `.txt` and `.tsv` directly in that folder) | The data pipeline and the project's own word lists |
| `Packages/AppCore/Sources/Injection/` | Text injection (edit jobs, strategies, the worker) |
| `Packages/AppCore/Sources/InputHost/` | The input host: event tap, key pipeline, focus, engine bridge |
| `Packages/AppCore/Sources/RealtimeSupport/`, `Packages/AppCore/Sources/CRealtimeSupport/` | Helpers the event tap uses |
| `App/Sources/Composition/ProductionServices.swift` | Where the app creates the event tap and wires the host |

**Excluded**, because they are not authored engine or input-handling code or are generated: every `Tests/` folder
and test fixture, `Packages/VietnameseEngine/Sources/VietnameseEngine/Generated/` (generated from Unicode data by
`Packages/VietnameseEngine/Scripts/generate-letter-table.py`; compare the generator instead if you like),
`Packages/VietnameseEngine/Sources/VietnameseEngineData/Resources/` (built output), `data/derived/`, `data/corpus/`,
the third-party inputs `data/inputs/english/` and `data/inputs/legal/` (their licences are checked by the record
review), `Packages/VietnameseEngine/Sources/VietnameseEngineTesting/`, `Packages/VietnameseEngine/Sources/site-demo-frames/`
(website tool) and everything outside the table.

**Compared projects** (the comparison set): the input methods named in CLR-R1 and CLR-R2 and in the clean-room
notice of `CLAUDE.md`: XKey, OpenKey, Unikey (including ibus-unikey and fcitx-unikey), PHTV, Vikey, LibreKey, EVKey,
GoTiengViet, Gõ Nhanh, vi-rs, bamboo-core and VietTelex, and any fork of these the reviewer knows of. For each, take
the latest public release (tag) at the date of the review, or the default branch's head when the project has no
release. Record per project, in the reviewer's own notes and in the report only as "project name, release or
commit, retrieved on": nothing else about it. A project with no public source is recorded as "no public source"
and skipped.

## 5. Tools

Use open-source tools that run locally, so neither tree is uploaded anywhere. Read each tool's current
documentation and record the exact version you ran.

| Tool | Why | Notes from its public documentation (checked 2026-11-18) |
|---|---|---|
| [JPlag](https://github.com/jplag/JPlag) | Token-based comparison with a Swift language module | Language set with `-l` (`swift` is a beta module); `-t` sets the minimum token match; `--old` takes prior submissions to compare against, so each compared project can be an "old" root and {{AppName}} the "new" one; `-bc` excludes base code; `-n -1` shows every comparison; `-r` names the result file; a `text` mode exists (naive, use with caution) for files in other languages. Results stay on the machine |
| [Dolos](https://dolos.ugent.be/docs/) | A second, independent algorithm (Tree-sitter tokens, k-gram fingerprints with winnowing) | `dolos run -l <language> <files>`; `-k` and `-w` set the k-gram and window lengths; `-f csv` or `-f web` for output. Swift is not in the default parser set: install a Tree-sitter Swift parser locally as its "Adding a language" page describes, or skip Dolos for Swift and record that |
| An identifier-set comparison | Catches copied names that token tools normalise away | The reviewer's own script: extract the identifiers (types, functions, constants, enum cases, file names) of each side and intersect them, case-insensitively and after splitting camel case. Not shipped in this repository, on purpose |
| A manual read | The only step that decides | The top-ranked pairs of each tool and every identifier overlap that is not common vocabulary (section 6) |

Command template (fill in the angle brackets; adapt to the versions you run and record the exact lines in the
report):

```sh
# {{AppName}} side: copy the paths of section 4 at the target commit into one folder.
git -C <app-clone> checkout <target-commit>
mkdir -p <work>/new/{{app-slug}}
# copy every path of section 4 into <work>/new/{{app-slug}}, keeping the relative paths, without the exclusions

# Compared side: one folder per project, at the recorded release, under <work>/old/.

# JPlag, Swift module, one run per compared project written in Swift:
java -jar <jplag.jar> -l swift -t <min-tokens> -n -1 \
  --new <work>/new --old <work>/old/<project> -r <work>/out/jplag-<project>

# JPlag text mode for a compared project in another language (weak signal, read every hit):
java -jar <jplag.jar> -l text -t <min-tokens> -n -1 \
  --new <work>/new --old <work>/old/<project> -r <work>/out/jplag-text-<project>

# Dolos, when a parser for the language exists:
dolos run -l <language> -f csv <files of both sides>    # output location: see dolos run --help

# Identifier sets:
<your-script> <work>/new > <work>/out/ids-app.txt
<your-script> <work>/old/<project> > <work>/out/ids-<project>.txt
comm -12 <work>/out/ids-app.txt <work>/out/ids-<project>.txt > <work>/out/ids-shared-<project>.txt
```

## 6. Thresholds and what counts as a finding

Starting values; tighten them if the scores of unrelated projects run high, and record the values used.

- Read by hand every file pair with a JPlag maximum similarity of **20 % or more**, every matched section of
  **40 tokens or more**, every Dolos pair in the top 20 by similarity or with a longest fragment of 30 tokens or more,
  and every shared identifier that is not common vocabulary.
- **Common vocabulary is not a finding**: words and letters of Vietnamese orthography (tone names, vowel and
  consonant letters, rhymes), the Telex and VNI key letters, Unicode code points and character names, Apple API and
  Swift standard library names, and anything `spec/` itself prescribes (a rhyme list in the spec's order, a rule
  order the spec numbers, a requirement ID). Tables that transcribe the spec or Unicode data in their source's order
  are expected; the record review checked that each cites its source.
- **A finding** is a similarity beyond what the spec and Vietnamese orthography force: the same sequence of
  identifiers or statements, the same structure of a function or a state machine, the same data-structure layout,
  bit layout or table ordering where the spec leaves the choice open, the same comment wording or the same unusual
  mistake, quirk or magic number.

Classify each finding: `inevitable` (with the reason, which must name the spec section or the orthography fact that
forces it), `suspect` (cannot be explained by the spec, may be chance) or `match` (copied or derived).

**Verdict** of the report:

| Verdict | When |
|---|---|
| `pass` | No finding, or only `inevitable` ones |
| `pass with notes` | Only `inevitable` findings plus remarks that need no rewrite (for example a weak text-mode hit judged chance) |
| `fail` | At least one `suspect` or `match` |

## 7. The report

The reviewer writes `docs/provenance/reports/<YYYY-MM-DD>-similarity-<short commit>.md` (the date the report is
signed and the first 8 characters of the target commit) from the template in section 9, and hands it to the
maintainer, who commits it on `main` unchanged apart from the acknowledgement line and adds a row to the index of
the [provenance README](../provenance/README.md).

The report holds only:

- {{AppName}} paths and line ranges at the target commit;
- the names and versions of the compared projects and the date each was retrieved;
- tool names, versions, parameters and scores;
- per finding: category, class and the reason;
- the verdict and the reviewer's signed statement.

It never holds code, file names, paths, identifiers, data, comments or summaries of another project. (This is
stricter than the record review's template, which asked for locations in the compared project; for this
comparison the paths of the other side stay with the reviewer.)

## 8. When there is a finding

1. The maintainer opens a tracking issue that names only the {{AppName}} paths and line ranges of the finding and
   links the report. No other detail.
2. Someone who has not seen the matching code, and has not read the report's reasoning beyond the paths, rewrites
   the affected code from `spec/` only (CLR-R4, CLR-R13). The rewrite replaces the code; it does not edit the
   matching lines into a different shape.
3. The reviewer re-runs the comparison on the rewritten paths and adds a re-check row to the report (new commit,
   new scores, new class). The verdict changes to `pass` or `pass with notes` only when no `suspect` or `match`
   remains.
4. A release waits until then. A finding in already shipped code goes into the next release, with a line in the
   changelog that the code was rewritten for provenance reasons, and no detail of the other project.

## 9. Report template

Copy this block into the new report file.

```markdown
# Similarity review report (CLR-R13): <short commit>

Runbook: [similarity-review.md](../../runbooks/similarity-review.md). This report contains no code, path,
identifier or description of any other project.

## 1. Target

| Field | Value |
|---|---|
| Commit reviewed | <full SHA> (<release, for example 1.0.0 or 1.0.1>) |
| Run | first run / delta since <previous similarity report and its commit> / targeted (<pull request>) |
| Paths compared | the table of runbook section 4 (delta: list the changed paths) |
| Date of review | <YYYY-MM-DD> to <YYYY-MM-DD> |

## 2. Reviewer

| Field | Value |
|---|---|
| Name | <name> |
| Appointed by the maintainer on | <date> |
| Allowed to read the compared codebases | yes |
| Has never contributed to this repository, and no coding assistant of the reviewer worked on it | yes |

## 3. Compared projects

| Project | Release or commit | Retrieved on |
|---|---|---|
| <name> | <tag or commit, or "no public source"> | <date> |

## 4. Tools and parameters

| Tool | Version | Parameters |
|---|---|---|
| JPlag | <version> | <language, -t, other options> |
| Dolos | <version, or "not run" with the reason> | <language, -k, -w> |
| Identifier comparison | <description of the reviewer's method, no output> | <normalisation> |
| Thresholds used | | <runbook section 6 values, or the tightened ones> |

## 5. Scores

| Compared project | Tool | Highest pair score | Pairs read by hand |
|---|---|---|---|
| <name> | <tool> | <score, with the {{AppName}} path of that pair> | <count> |

## 6. Findings

| # | {{AppName}} path and lines | Category (identifier / structure / layout / table order / comment / quirk) | Class (inevitable / suspect / match) | Reason (for inevitable: the spec section or orthography fact) |
|---|---|---|---|---|

## 7. Re-checks after rewrites

| Finding # | Rewritten in commit | New score | New class |
|---|---|---|---|

## 8. Verdict and statement

Verdict: **pass / pass with notes / fail**

Statement: I compared the {{AppName}} paths listed above at the commit above with the projects listed above, using
the tools and thresholds listed above, and read every pair and overlap above the thresholds myself. I did not
copy, paste or describe any code, path or identifier of another project into this report or into the {{AppName}}
repository, and I did not discuss the internals of another project with the maintainers or their coding tools.

Signed: <name>, <date>

Maintainer acknowledgement: <name>, <date>
```
