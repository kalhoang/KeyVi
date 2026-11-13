# 0320. Learned words are stored per app

- Status: accepted, 2026-11-13
- Requirements: ENG-R851, ENG-R860, ENG-R861, ENG-R862, PRD-R6, PRD-R26, PRD-R66, PLT-R304, PLT-R305, PLT-R901,
  PLT-R1002, PLT-R1005, PLT-R1010
- Context: the product owner decided on 13/11/2026 (Q16 of [0005](0005-pa-decisions-2026-11-13.md)) that learning
  from restore toggles stays automatic, after two identical signals, but that a learned entry is stored with the app
  it was learned in and applies only there; entries typed in Settings stay global, and Settings shows the app of each
  learned entry and can remove it or make it global. Until then every learned word went into the global
  `keepAsTyped` or `keepVietnamese` list of `settings.json`, mixed with the words the user typed. The engine must
  keep knowing nothing about apps (ENG-R851). Workstream W5-B.

## Decision

1. **Model.** `UserSettings.keepAsTyped` and `keepVietnamese` are the global entries. Learned entries are
   `UserSettings.learnedWords`, a set of `LearnedWord` (`list`, lowercased `raw` keys, `app` bundle key). The app's
   display name is never stored; Settings resolves it from the bundle identifier when it shows the row (installed
   app, else the compatibility matrix name, else the identifier).
2. **Learning** (`LearningTracker`, `UserSettings.learn`). Signals are counted per app: the same list and raw keys
   twice in the same app make a proposal for that app. The app is the focused app when the main thread drains the
   tap's notice (the tap commits the token on the key the user just typed, so the focus has not moved yet). A signal
   without a known app is dropped. Applying a proposal removes the word from the other list's learned entries of that
   app (newest choice wins, ENG-R860) and adds nothing when a global entry already gives the app that behaviour.
   Learning never changes a global entry.
3. **Lists for the engine** (ENG-R851). `UserSettings.wordLists(for:)` returns the global entries plus the focused
   app's learned words; a word learned in the app wins over a global entry of the other list. The focused app's
   lists are the user lists of `Resources`. `TapSettingsPublisher` keeps the last settings and the focused app; when
   the focus moves (`InputHostController.refreshState` sees a new bundle and calls `focusChanged(to:)` on the
   utility queue, never on the tap, PLT-R304, PLT-R305) it rebuilds the engine catalog only if that app's lists
   differ from the current ones, and reuses the macro table. Moving between apps without learned words publishes
   nothing, so the word being typed is kept.
4. **Settings.** Each list shows its global entries and its learned entries by word; a learned row shows "Chỉ trong
   <app>" ("Only in <app>"), a "use in every app" button and a remove button, each with a VoiceOver label and hint
   (PRD-R66). "Use in every app" makes the word a global entry of its list, removes it from the other global list
   and drops the copies learned for the same list in other apps; words learned for the other list in other apps keep
   overriding it there. A word typed in Settings is global and makes the same-list learned copies redundant, so they
   are dropped. A note under the lists explains the app names when at least one word was learned. Resetting the
   Typing pane forgets the learned words with the lists (PRD-R26).
5. **File format, no schema change.** `settings.json` keeps schema version 1. `englishRestoreLists` gains an optional
   array `learnedWords` of `{"list": "keepAsTyped" | "keepVietnamese", "raw": "<keys>", "app": "<bundle key>"}`,
   sorted by word, list and app. Unknown keys inside an item survive a rewrite (PLT-R1002); an unreadable item is
   skipped and listed among the skipped fields of an import (PLT-R1010). Builds without per-app learning keep the
   key unread and rewrite it unchanged, so no reader breaks and no migration step is needed (PLT-R1005 asks for a
   step only when the schema version changes).
6. **Migration.** Files written before this change have no `learnedWords`: their `keepAsTyped` and `keepVietnamese`
   entries, which mixed typed and learned words without an app, are read as global entries, exactly as before. A
   `learnedWords` item without an `app` (or with `null`) is also read as a global entry of its list. This is
   recorded on `MigrationChain.shipped` and tested on the released v1 fixture
   (`LearnedWordsCodecTests.filesFromBeforePerAppLearningKeepTheirEntriesGlobal`).
7. **Export and import** carry the app: the export's `settings` section is the settings document, so
   `learnedWords` travels with it, and the import preview lists `learnedWords` among the changed keys.
8. **Diagnostics.** The report names the list `learnedWords` among the explicitly set keys when it is not empty,
   like the other user lists of [0314](0314-report-lists-user-word-lists-by-name.md); no word and no app reaches the
   report or the log (PLT-R901).

## Alternatives considered

- **Bump `settings.json` to schema 2 and store every entry as `{raw, app?}` inside the two lists.** Rejected: it
  changes nothing for the files that exist (their entries are global either way) but would make every older build
  open the file read-only (PLT-R1007).
- **Prebuild one engine catalog per app with learned words and let the tap pick it at focus changes.** Rejected: the
  tap would hash a bundle identifier per focus change and the catalog count would grow with the user's apps; the
  focus-driven rebuild costs one catalog build on the utility queue, only when the lists differ.
- **Carry the bundle identifier in the tap's learning notice.** Better attribution in the rare case where the focus
  changes between the commit and the main thread's drain, but it changes the pipeline's notice type, owned by the
  input host workstream; requested there (see the workstream report) and compatible with this design.

## Consequences

- A user who corrects the same word twice in one app no longer changes its behaviour in every other app; the same
  word can have different learned entries in different apps.
- A focus change to an app whose lists differ rebuilds the eight engines once on the utility queue, within
  milliseconds of the focus change. A key typed in that app before the new snapshot arrives is composed with the
  previous lists, and the engine swap that follows is a configuration-change boundary (PLT-R340) that ends the word
  being typed.
- An older build that writes `settings.json` keeps `learnedWords` as it was, but its own learning still adds words
  to the global lists.
