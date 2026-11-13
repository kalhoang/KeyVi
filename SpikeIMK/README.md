<!-- SPDX-License-Identifier: LicenseRef-App-Pending -->
# Spike S1: InputMethodKit under Secure Keyboard Entry (PLT-R398D)

## Question

Event taps stop receiving keys while an app holds Secure Event Input (Apple TN2150), so the menu-bar app pauses
in Terminal and iTerm2 when their "Secure Keyboard Entry" is on. Does an InputMethodKit (IMK) input source
still receive key events there, and can it still commit text? If yes, a later 1.x "terminal mode" can use an
IMK input source for apps that hold secure input (PLT-R207). If no, the pause with an honest explanation stays
the only behaviour.

## What the spike does

`SpikeIMK.app` is a minimal IMK input method (an `IMKServer` with one `IMKInputController`):

- It counts key-down events it receives, and how many of them arrived while `IsSecureEventInputEnabled()` was
  true. It never records which keys were pressed.
- Its input menu (the input-source icon in the menu bar while SpikeIMK is selected) shows the counters, the
  current secure-input state, a "Reset counters" item and a "Commit test" toggle.
- With "Commit test" ticked, typing `;` inserts `✓` through the IMK client instead. Everything else passes
  through unchanged. With the toggle off (the default), every key passes through.
- It never creates an event tap and never posts synthetic events (PLT-R207). It is never shipped.

## Build

From the repository root, on a Mac with Xcode 27 and XcodeGen:

```sh
xcodegen generate
xcodebuild -project App.xcodeproj -scheme SpikeIMK -configuration Debug -derivedDataPath build/spike build
```

The product is `build/spike/Build/Products/Debug/SpikeIMK.app`, signed with the Debug identity from
`Config/Signing.xcconfig` (Apple Development, team N2J45D3NKD). Its bundle ID is the development bundle ID from
`Config/Brand.xcconfig` plus `.inputmethod.SpikeIMK`; macOS looks for `.inputmethod.` in input method bundle IDs.

## Install and enable (Pa, by hand)

1. Copy the bundle: `mkdir -p ~/Library/Input\ Methods && cp -R build/spike/Build/Products/Debug/SpikeIMK.app ~/Library/Input\ Methods/`.
2. Log out and back in (macOS registers new input methods at login; on some versions it is enough to wait a
   few seconds).
3. Open System Settings > Keyboard > Text Input > Input Sources > Edit, click `+`, choose Vietnamese, select
   "SpikeIMK" and add it. The exact labels can differ slightly between macOS versions.
4. Select SpikeIMK in the input menu of the menu bar. The icon is a square with "S1".
5. Quit the menu-bar app under test (or make sure it is not running) so its event tap does not interfere.

## Test procedure

Run each row twice: once with SpikeIMK's "Commit test" off, once with it on. Use "Reset counters" before
each row and read the counters from the input menu after typing about 20 keys.

| # | App | Secure Keyboard Entry | How to turn it on |
|---|---|---|---|
| 1 | TextEdit | off (control row) | n/a |
| 2 | Terminal | off | Terminal menu > Secure Keyboard Entry unticked |
| 3 | Terminal | on | Terminal menu > Secure Keyboard Entry ticked |
| 4 | iTerm2 | off | iTerm2 menu > Secure Keyboard Entry unticked |
| 5 | iTerm2 | on | iTerm2 menu > Secure Keyboard Entry ticked |
| 6 | iTerm2 | automatic (password prompt) | run `sudo -k; sudo true` and type at the password prompt without pressing Return; press Control+C afterwards |

What to record for each row:

- "Key-downs received" and "Received while secure input on" after typing.
- "Secure input now" while the app is frontmost (expected `on` in rows 3, 5 and 6).
- With "Commit test" on: whether `✓` appeared in the app for each `;`, and the two commit counters.

## Remove

1. System Settings > Keyboard > Text Input > Input Sources > Edit: select SpikeIMK and click `-`.
2. Move `~/Library/Input Methods/SpikeIMK.app` to the Trash.
3. Log out and back in.

## Result template

Record the result as `docs/decisions/03NN-spike-s1-result.md` (next free number in 0300-0399):

```markdown
# 03NN. Spike S1 result: InputMethodKit under Secure Keyboard Entry

- Status: accepted, YYYY-MM-DD
- Requirements: PLT-R398D, PLT-R207, P0-1
- Environment: macOS <version> (<build>), <Mac model>, Terminal <version>, iTerm2 <version>

## Measurements

| # | App | Secure entry | Key-downs | While secure | Secure now | Commit test: ✓ shown | Commits while secure |
|---|---|---|---|---|---|---|---|
| 1 | TextEdit | off | | | | | |
| 2 | Terminal | off | | | | | |
| 3 | Terminal | on | | | | | |
| 4 | iTerm2 | off | | | | | |
| 5 | iTerm2 | on | | | | | |
| 6 | iTerm2 | automatic | | | | | |

## Decision

- IMK receives keys under secure input: yes / no.
- IMK can commit text under secure input: yes / no.
- Consequence: plan a 1.x terminal mode under PLT-R207 / keep the pause with explanation only.
```
