# Runbook: tart VM test lab on the maintainer's Mac

Owner: the maintainer. Specification: PLT-R105, PLT-R106, QA-R10 to QA-R13, [ADR 0315](../decisions/0315-minimum-macos-12.md)
("macOS 12 smoke test"). Pa approved the lab on 2026-11-13 (answer S6/Q12): macOS virtual machines run with
[tart](https://tart.run) on Pa's Mac, everything stored on `/Volumes/Data`.

The lab gives two things the hosted CI cannot: a real macOS 12 system for the smoke test of ADR 0315, and a
macOS with Xcode where synthetic events, TCC grants and app launches are allowed, for the integration suite
([integration-suite.md](integration-suite.md)) and later the self-hosted runner
([self-hosted-runner.md](self-hosted-runner.md) section 8).

**The boundary that matters:** on the host (Pa's Mac) nothing built here is ever launched, no event is posted,
no event tap is created, no TCC or System Settings change is made, and no `sudo` is used. Inside a VM all of
that is allowed. The scripts in `scripts/vm/` only run apps inside VMs.

## 1. What lives where

| Path | Contents |
|---|---|
| `/Volumes/Data/tart/tart.app` | tart 2.41.1, the notarized release of Cirrus Labs (not Homebrew: the Homebrew tap moved and needs `brew trust`) |
| `/Volumes/Data/tart/home` | `TART_HOME`: `vms/` (local VMs), `cache/OCIs/` (pulled images). Every tart call must set `TART_HOME`; `scripts/vm/lib.sh` always does |
| `/Volumes/Data/tart/keys` | The lab's own SSH key pair (`id_ed25519`), its `known_hosts` file and the askpass helper (mode 0700). `~/.ssh` is never read or written |
| `/Volumes/Data/tart/state` | `tart run` logs, pid and IP files of running VMs, `clones/` markers of throwaway clones |
| `/Volumes/Data/tart/runs` | One folder per smoke test run (`<UTC timestamp>-macos12/`) |
| `scripts/vm/lab.sh` | The command line (section 4); `scripts/vm/lib.sh` holds the shared functions |
| `scripts/vm/smoke-macos12.sh` | The macOS 12 smoke test (section 6); `scripts/vm/guest/smoke-guest.sh` is its half that runs inside the VM, `scripts/vm/macho-info.pl` reads slices and `minos` without Xcode |
| `scripts/vm/upgrade-test.sh` | The release candidate's upgrade test, channel switch and egress test (section 12); `scripts/vm/guest/upgrade-guest.sh` and the guest tools next to it run inside the VM, `scripts/vm/upgrade-report.py` checks the artefacts and decides on the host |

The two local VMs. Their names follow the slug of `scripts/brand.env` (`VM_MONTEREY`, `VM_DEV`):

| VM | Image | What is in it |
|---|---|---|
| `{{app-slug}}-monterey` | `ghcr.io/cirruslabs/macos-monterey-vanilla:12.7.6` (digest `sha256:4bc904cf8f2447dfa6e6fb9a5eb70eba14196dd0f4236d30fc92aff9c2391842`) | macOS 12.7.6 (21H1320), SIP enabled, command line tools, passwordless `sudo` for `admin`, no tart guest agent. The lab added Rosetta 2 and its SSH key on 2026-11-13 |
| `{{app-slug}}-dev` | `ghcr.io/cirruslabs/macos-golden-gate-xcode:27.2` (digest `sha256:d7641b1d985fd53fbac071c663bf249007b9b387e16b7d576144588acb1d93f9`) | macOS 27.2 (26B123), Xcode 27.2 (27B52) at `/Applications/Xcode_27.2.app`, Swift 6.4.2, **SIP disabled**, tart guest agent running (`tart exec` works), passwordless `sudo`, Rosetta 2, 125 GB disk (42 GB free), no signing identity, no XcodeGen or Homebrew on the SSH `PATH`. The lab added its SSH key on 2026-11-13 |

Cirrus Labs images log in automatically as `admin` (password `admin`, a public default of the images) and have
Remote Login on. The first `up` of a VM installs the lab key into `admin`'s `authorized_keys` with one password
login; clones inherit it.

## 2. Disk use

Measured on 2026-11-13 with `du`: `cache/OCIs` 109 GB, `vms/{{app-slug}}-dev` 83 GB, `vms/{{app-slug}}-monterey`
26 GB. The local VMs are APFS clones of the cached images, so the real footprint is about 110 GB plus what each
VM wrote since (a few GB). A throwaway clone costs only the blocks the run writes and is deleted at the end of
the run. `/Volumes/Data` had 651 GB free.

## 3. Memory and CPU sizing

The host has 16 GB and 10 CPUs and runs other jobs (up to five parallel builds at once), so:

- one VM at a time: `up`, `with` and the smoke test refuse to start a VM while any local VM runs (exit 3);
- defaults: `{{app-slug}}-monterey` and its clones 4096 MB and 2 CPUs, `{{app-slug}}-dev` and its clones 6144 MB and
  4 CPUs; `--memory MB` and `--cpus N` override them up to `VM_LAB_MAX_MEMORY_MB` (8192) and `VM_LAB_MAX_CPUS` (6);
- before booting the 6 GB VM, look at `memory_pressure` on the host; with heavy swapping, wait for builds to end;
- any time of day is fine (the product owner, 18/11/2026, [ADR 0009](../decisions/0009-pa-decisions-2026-11-18.md)
  item 7) as long as that check passes: no heavy swapping (`memory_pressure`), the load average below the CPU count
  (`uptime`), and enough free disk for a clone (`scripts/vm/lab.sh status`); otherwise wait;
- every script stops the VMs it started when it exits, also on failure or Ctrl-C (`trap` in `lib.sh`). Only
  `lab.sh up` leaves a VM running on purpose; stop it with `lab.sh down`.

## 4. Commands

```sh
scripts/vm/lab.sh status                          # local VMs, which one runs, free disk
scripts/vm/lab.sh up {{app-slug}}-monterey          # headless boot, waits for IP and SSH (about 1 to 2 minutes)
scripts/vm/lab.sh ssh {{app-slug}}-monterey 'sw_vers'
scripts/vm/lab.sh push {{app-slug}}-monterey ./Some.app inbox   # tar over SSH: keeps symbolic links and signatures
scripts/vm/lab.sh pull {{app-slug}}-monterey inbox/out ./out
scripts/vm/lab.sh probe {{app-slug}}-dev            # macOS, SIP, Xcode, sudo, Rosetta, guest agent
scripts/vm/lab.sh exec {{app-slug}}-dev uname -a    # through the tart guest agent (not in vanilla images)
scripts/vm/lab.sh down {{app-slug}}-monterey        # guest shutdown, then tart stop, then kill tart run
scripts/vm/lab.sh with {{app-slug}}-monterey -- ./my-check.sh   # boot, run with VM_NAME and VM_IP, always stop
scripts/vm/lab.sh clone {{app-slug}}-monterey {{app-slug}}-monterey-try   # throwaway APFS clone
scripts/vm/lab.sh delete {{app-slug}}-monterey-try  # only clones made by `clone` can be deleted
```

To see the screen of a VM (for a one-time grant, [integration-suite.md](integration-suite.md) section 10.2), stop
it and run `TART_HOME=/Volumes/Data/tart/home /Volumes/Data/tart/tart.app/Contents/MacOS/tart run <vm>` in a
Terminal: that opens the VM window. Close the window (or shut the guest down) when done.

Exit status of `lab.sh`: 0 success, 1 failure, 2 usage error, 3 refused by a safety rule.

## 5. Safety rules

1. Host and guest stay apart: nothing in `scripts/vm/` launches an app, posts events or changes settings on the
   host. The smoke test builds on the host and runs the app only inside the VM. The scripts meant for the guest
   (`guest/smoke-guest.sh`, `guest/integration-guest.sh`, `guest/upgrade-guest.sh` and its tools, `grant-tcc.sh`)
   check `kern.hv_vmm_present` first and exit 3 on a real Mac, before they parse an argument or touch anything.
2. One VM at a time, and a script stops what it started (section 3).
3. Only throwaway clones are deleted: `lab.sh delete` refuses a VM without the marker that `lab.sh clone`
   writes, so `{{app-slug}}-monterey` and `{{app-slug}}-dev` cannot be deleted by a script. Deleting a base VM is
   Pa's decision (a new pull is about 110 GB).
4. `lab.sh clone` sets `TART_NO_AUTO_PRUNE=1`, so a clone never evicts cached images on its own.
5. SSH uses only the lab key: `-F /dev/null`, `IdentitiesOnly=yes`, no agent, `StrictHostKeyChecking=no` with
   the lab's own `known_hosts` (VM addresses on the host-only network `192.168.64.0/24` are reused and clones
   share host keys, so `up` forgets the old key of an address). The password reaches `ssh` only through
   `SSH_ASKPASS` with `SSH_ASKPASS_REQUIRE=force` and an environment variable; it is never written to a file.
6. No secrets in a VM: no Developer ID or Sparkle keys, no notarization profile, no tokens kept on disk. A
   runner registration token is short-lived and passed on standard input ([self-hosted-runner.md](self-hosted-runner.md)
   section 8).
7. Remote paths given to `push` and `pull` may not contain quotes, backquotes, `$` or backslashes.

## 6. macOS 12 smoke test

```sh
scripts/vm/smoke-macos12.sh                       # build, then test in a throwaway clone of {{app-slug}}-monterey
scripts/vm/smoke-macos12.sh --app path/to/App.app # test an existing build (a release candidate, for example)
```

What it does (ADR 0315, PLT-R105, PLT-R106):

1. Builds the app with `xcodebuild -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO
   CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS= ENABLE_HARDENED_RUNTIME=NO`
   in `/tmp/vm-smoke-dd` (never on `/Volumes/Data`, where xcodebuild times out). Ad-hoc signed, so it can run
   without an identity; the hardened runtime is off because an ad-hoc signature has no Team ID and library
   validation then refuses the embedded Sparkle framework (seen on the first run, section 6.1).
2. Checks on the host that both slices exist with `minos 12.0` or older (a newer `minos` fails here, before any
   VM boots), then refuses early if another VM runs.
3. Clones `{{app-slug}}-monterey` to `{{app-slug}}-monterey-smoke`, boots it (4096 MB, 2 CPUs), copies the app and the
   guest script in, and inside the VM: records the system, verifies the signature, checks `lipo -archs` and
   `minos` of each slice, installs Rosetta with `softwareupdate --install-rosetta --agree-to-license` if missing,
   installs the app into `/Applications` (the location PLT-R710 asks for), launches the arm64 slice through
   LaunchServices and the x86_64 slice with `arch -x86_64` in the user's GUI session (macOS 12's `open` has no
   `--arch` option), requires each process (matched by its name) to stay alive for the window (default 20 s)
   with `Sparkle.framework` mapped, under Rosetta only for x86_64, with no dyld or missing-symbol error on its
   standard error or in the unified log and no crash report, collects the unified log of the app's subsystem and
   process and any crash report, then quits it.
4. Copies the guest logs back, prints `RESULT: PASS` or `RESULT: FAIL`, stops the VM and deletes the clone.

The app asks for Accessibility permission in the VM; that is expected. The smoke test proves only that the
app launches and stays up on macOS 12, natively and under Rosetta; the release checklist steps of ADR 0315
(onboarding, typing, Login Items note, update check) stay manual.

Run folder `/Volumes/Data/tart/runs/<timestamp>-macos12/`: `summary.txt` (the PASS and FAIL lines),
`smoke.log`, `build.log`, `host-macho.txt`, `guest.log`, and `out/` with `vm-info.txt`, `macho.txt`,
`codesign.txt`, `rosetta-install.txt` and, per slice (`arm64/`, `x86_64/`): `stdout.txt`, `stderr.txt`,
`lsof.txt`, `ps.txt`, `unified.log`, `crash/`.

A run takes about 6 to 11 minutes (build, boot about 1 to 2 minutes, Rosetta about 1 minute when missing, two
windows of 20 s plus log collection).

### 6.1 Results

Run on 2026-11-13 on Pa's Mac (Apple M4, host macOS 27.2), guest `{{app-slug}}-monterey` 12.7.6 (21H1320), commit
`f6bb823` and its fix `d9976fe`:

| Run | Result | What it showed |
|---|---|---|
| `20261113T142257Z-macos12` | FAIL, and two defects of the script | macOS 12's `open` rejects `--arch`, so both slices started through the `launchctl asuser` fallback; `pgrep -f` then matched the `sudo` wrapper, so the arm64 "pass" watched the wrapper (no log line of the app, Sparkle not mapped) and does not count. The x86_64 slice was refused by dyld: `Library not loaded: '@rpath/Sparkle.framework/Versions/B/Sparkle' ... code signature ... not valid for use in process: mapped file has no Team ID and is not a platform binary (signed with custom identity or adhoc?)`. Cause: an ad-hoc signature with the hardened runtime, whose library validation needs a Team ID. Not a product defect: the Developer ID build signs the app and Sparkle with one Team ID. Rosetta was missing and installed fine |
| `20261113T144106Z-macos12` | **PASS** | Fixed script (process matched by name, Sparkle must be mapped, arm64 through LaunchServices) and the smoke build with the hardened runtime off. Host and guest: slices `x86_64 arm64`, both `minos 12.0` (SDK 27.2), signature valid. arm64: started by LaunchServices (parent `launchd`), alive 20 s, not translated, Sparkle mapped, `lifecycle.launched` and `host.state` logged by the app's own subsystem (values private), an Accessibility request to `tccd` as expected, empty standard error, no crash report. x86_64: started with `arch -x86_64`, alive 20 s, `libRosettaRuntime` and the Rosetta translation mapped, Sparkle mapped, `lifecycle.launched` logged, no dyld error, no crash report |

The run folders stay under `/Volumes/Data/tart/runs/` on Pa's Mac.

## 7. Integration suite in `{{app-slug}}-dev`

`scripts/vm/integration-dev.sh` runs the QA-R11 TestHost suite in a throwaway clone of `{{app-slug}}-dev` (SIP
disabled, so `scripts/vm/grant-tcc.sh` grants TCC). The guest half enables the input sources the scenarios select
(`scripts/vm/guest/enable-input-sources.swift`, in the guest only) and builds with `scripts/run-integration.sh build`
and `INTEGRATION_CODE_SIGN_IDENTITY=-` (ad hoc, hardened runtime off), so the VM and the runner share one build
step. `--only ID[,ID...]` (scenario IDs or `PREFIX*` patterns) runs only those TestHost scenarios, for a control
run of one failure on a fresh TestHost (`scripts/vm/integration-dev.sh --only testhost.web.textarea`). How it works,
the result of the first attempt and the manual grant for an image with SIP enabled:
[integration-suite.md](integration-suite.md) section 10. The runner plan:
[self-hosted-runner.md](self-hosted-runner.md) section 8.

## 8. Cleanup

- Throwaway clones: deleted by the script that made them; a leftover from a killed run shows in
  `lab.sh status` and goes with `lab.sh delete <name>` (the smoke test also removes its own stale clone).
- Cached images: `tart prune --entries caches --older-than 30` (with `TART_HOME` set) removes images not used
  for 30 days; `--space-budget 50` keeps the cache under 50 GB. Because the local VMs are APFS clones, pruning
  frees only the blocks the VMs no longer share; it never touches the local VMs. A new clone of a pruned image
  needs a new pull.
- Run folders under `/Volumes/Data/tart/runs/` are plain files: delete old ones by hand when they are no longer
  needed for a release record.
- After `scripts/rename-app.sh`, rename the VMs to the new slug (`tart rename <old-slug>-monterey <new-slug>-monterey`,
  the same for `-dev`) or set `VM_MONTEREY` and `VM_DEV`.

## 9. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `refusing to start <vm>: <other> is running` | One VM at a time: `lab.sh down <other>` (or wait for the job that started it) |
| `no SSH answer from <ip>` | The guest is still booting under memory pressure: raise `VM_BOOT_TIMEOUT` (default 420 s) or free memory; `state/<vm>.log` shows tart's output |
| `could not install the lab key` | The image's password is not `admin`: set `VM_SSH_PASSWORD` for that one run |
| `tart exec failed` | The image has no tart guest agent (vanilla images): use `lab.sh ssh` |
| x86_64 slice: `mapped file has no Team ID and is not a platform binary` | An ad-hoc signed build with the hardened runtime: build with `ENABLE_HARDENED_RUNTIME=NO` (the default of the smoke build) or sign with a Team ID |
| A VM stays `running` after a killed script | `lab.sh down <vm>`; it falls back to `tart stop` and then kills `tart run` |
| `is the Tart Guest Agent running?` right after boot | The guest agent starts in the user session after SSH: `integration-dev.sh` waits up to `VM_AGENT_TIMEOUT` (180 s) for it |
| `ssh` and `tart exec` hang after a long run | The 6 GB guest is swapping (it was Spotlight indexing the checkout until the guest script turned indexing off): `tart stop <vm>` (with `TART_HOME` set) still works |

## 10. System pane names (`SystemPanes.json`)

Specification: PLT-R704, PRD-R64, PLT-R398C, [ADR 0315](../decisions/0315-minimum-macos-12.md), decision 0005 Q37
([0005](../decisions/0005-pa-decisions-2026-11-13.md)). `App/Resources/SystemPanes.json` holds, per macOS version and
macOS language, the names of System Settings (macOS 13 and later) or System Preferences (macOS 12) that the app's copy
quotes, and the deep links it opens. Each entry's `_verify` note says what was checked and what is still VERIFY. Two
checks exist, the first one stronger.

### 10.1 On screen: `scripts/vm/pane-names.sh`

```sh
scripts/vm/pane-names.sh --vm {{app-slug}}-monterey    # macOS 12.7.6, English then Vietnamese
scripts/vm/pane-names.sh --vm {{app-slug}}-dev         # macOS 27.2
scripts/vm/pane-names.sh --vm {{app-slug}}-dev --languages vi --output /Volumes/Data/tart/runs/<name>
```

What it does, in the throwaway clone `<vm>-panes` (deleted at the end, like every lab clone):

1. Refuses to start while Safari runs on the host (the maintainer is using the Mac; checked again before every
   reboot), or while another VM runs (section 3). Then, before any VM starts, it compiles
   `scripts/vm/guest/ax-dump.swift` (an Accessibility reader that refuses a real Mac) on the host with
   `swiftc -O -target arm64-apple-macos12.0` and never runs it there. The guest gets the binary, not the source: the
   macOS 12 lab image has no command line tools, so `swiftc` in it is only the `xcode-select` shim (the same reason
   `guest/smoke-guest.sh` avoids `lipo`).
2. Picks the `SystemPanes.json` entry that `SystemPaneTable` uses for the guest's macOS version and writes its deep
   links to `links.tsv`, plus probe links that show the remaining names (macOS 12: the Privacy tab and the Text tab;
   macOS 13 and later: Privacy & Security and General).
3. With SIP disabled (`{{app-slug}}-dev`), grants Accessibility and Screen Recording to
   `/usr/libexec/sshd-keygen-wrapper` with `grant-tcc.sh`, so the SSH session can read windows and take screenshots.
   With SIP enabled (`{{app-slug}}-monterey`) that grant has to be in the base VM already: add
   `/usr/libexec/sshd-keygen-wrapper` to Accessibility and to Screen Recording once by hand, as in
   [integration-suite.md](integration-suite.md) section 10.2 (this changes the base VM: the maintainer's decision).
   Without it the guest reports `trusted: no` and reads nothing.
4. For each language (`en`, then `vi`): sets `AppleLanguages` (`vi en` for Vietnamese) and `AppleLocale` of the guest
   user, reboots the clone so the login session and every System Settings extension start in that language, and runs
   `scripts/vm/guest/pane-names-guest.sh --tool inbox/panes/ax-dump` over SSH (given `ax-dump.swift` instead, the
   guest compiles it only when `xcode-select -p` finds the command line tools, and stops otherwise). For each link it
   quits System Settings, opens the link in the
   logged-in session (`launchctl asuser`), dumps the window that opened (roles, titles, values, selection) and takes
   a screenshot, then dumps the app's menus (its name is the title of the application menu) and Terminal's menus,
   with a screenshot of Terminal's application menu open.

Run folder `VM_LAB_RUNS/<timestamp>-panes-<vm>/` (or `--output`): `pane-names.log`, `links.tsv`, `guest-<lang>.log`
and one folder per language with `system.txt`, `summary.txt`, `trusted.txt`, `<link>.ax.txt` and `<link>.png` per
link, `settings-menus.ax.txt`, `terminal-menus.ax.txt`, `terminal-press.txt` and `terminal-menu.png`. The window
title and the selected row of each `<link>.ax.txt` show which pane and tab the link opened.

Self-tests: `python3 -I scripts/tests/test_pane_names.py` (part of `scripts/tests/run.sh`) drives `pane-names.sh`,
the guest script and `pane-tables.py` with fake `tart`, `ssh`, `pgrep`, `swiftc` and `sysctl`; no VM starts and
nothing is opened on the host.

### 10.2 Localization tables: `scripts/vm/pane-tables.py`

When no VM can boot, the spelling macOS ships can still be read from its localization tables, without booting
anything. It is weaker evidence: it shows how macOS spells a name, not that the pane shows it there, and it says
nothing about where a deep link lands.

```sh
python3 -I scripts/vm/pane-tables.py --root <mounted system volume> --check App/Resources/SystemPanes.json
```

For macOS 12, the system volume of a throwaway clone, attached read-only and never booted:

```sh
scripts/vm/lab.sh clone {{app-slug}}-monterey {{app-slug}}-monterey-panes
diskutil image attach --readOnly --noMount /Volumes/Data/tart/home/vms/{{app-slug}}-monterey-panes/disk.img
diskutil list <disk image device>         # the APFS container; its "Macintosh HD" volume is the system volume
diskutil mount readOnly -mountOptions nobrowse -mountPoint /tmp/panes-12 <container>s1
python3 -I scripts/vm/pane-tables.py --root /tmp/panes-12 --check App/Resources/SystemPanes.json
diskutil unmount /tmp/panes-12 && diskutil eject <disk image device>
scripts/vm/lab.sh delete {{app-slug}}-monterey-panes
```

For a macOS 13 or later build, `--root /` reads the running system; that counts for a lab VM only when the host runs
the VM's exact build (`sw_vers -buildVersion`). The script reads `InfoPlist.strings`, `Localizable.strings` and the
nib strings of System Preferences and its panes on macOS 12, the `.loctable` files of System Settings and its
extensions from macOS 13, and Terminal's main menu. Labels of a compiled nib keep their English text in
`Base.lproj` (reported as `base nib`). A button that opens a sheet carries an ellipsis (`Text Replacements…`); the
copy quotes the name without it. Exit status 0 when every compared name matches.

### 10.3 Results, 2026-11-14 (W7-D)

The on-screen check did not run: Safari was open on the host for the whole 90-minute wait, so no VM was booted. The
localization tables were read instead (section 10.2). Run folder `/Volumes/Data/tart/runs/w7d-20261114T035118Z/`:
`README.txt`, `tables-macos12.7.6-21H1320.tsv`, `tables-macos27.2-26B123.tsv`, `base-nib-english-macos12.7.6.txt`,
`anchors-macos12.7.6.txt` and `anchors-macos27.2.txt`.

macOS 12.7.6 (21H1320), from the system volume of a never-booted clone of `{{app-slug}}-monterey`:

| Name | English | Vietnamese | Source |
|---|---|---|---|
| App | System Preferences | Tùy chọn Hệ thống | `System Preferences.app` `InfoPlist.strings` `CFBundleName` |
| Security & Privacy (icon) | Security & Privacy | Bảo mật & Quyền riêng tư | `Security.prefPane` `NSPrefPaneIconLabel` (its `CFBundleName`: "Bảo mật & quyền riêng tư") |
| Privacy tab | Privacy (base nib) | Quyền riêng tư | `SecurityPref.strings` `201924.label` |
| Accessibility | Accessibility | Trợ năng | `Security.prefPane` `Localizable.strings` `ACCESSIBILITY` |
| Input Monitoring | Input Monitoring | **Giám sát Đầu vào** (was "Giám sát đầu vào") | `LISTEN_EVENT` |
| Keyboard | Keyboard | Bàn phím | `Keyboard.prefPane` `CFBundleName` |
| Text tab | Text | Văn bản | `IntlTexts.prefPane` `CFBundleName` |
| Users & Groups | Users & Groups | Người dùng & Nhóm | `Accounts.prefPane` `CFBundleName` |
| Login Items tab | Login Items (base nib) | **Mục Đăng nhập** (was "Mục đăng nhập") | `AccountsPref.strings` `122.label` |
| Terminal menu item | Secure Keyboard Entry (base nib) | Nhập dùng Bàn phím An Toàn | `Terminal.app` `MainMenu.strings` `511.title` |

macOS 27.2 (26B123), the build of `{{app-slug}}-dev`, read on the maintainer's Mac, which runs that build:

| Name | English | Vietnamese | Source |
|---|---|---|---|
| App | System Settings | Cài đặt hệ thống | `System Settings.app` `InfoPlist.loctable` |
| Privacy & Security | Privacy & Security | Quyền riêng tư & Bảo mật | `SecurityPrivacyExtension` `InfoPlist.loctable` |
| Accessibility | Device Control and Data Access | Điều khiển thiết bị và truy cập dữ liệu | `SecurityPrivacyExtension` `ACCESSIBILITY` |
| Input Monitoring | Input Monitoring | Giám sát đầu vào | `SecurityPrivacyExtension` `LISTEN_EVENT` |
| Keyboard | Keyboard | Bàn phím | `KeyboardSettings` `InfoPlist.loctable` |
| Text Replacements | Text Replacements… | Thay thế văn bản… | `KeyboardSettings` `Localizable.loctable` |
| General | General | Cài đặt chung | `GeneralSettings` `InfoPlist.loctable` |
| Login Items & Extensions | Login Items & Extensions | **Mục đăng nhập & Phần mở rộng** (was "Mục đăng nhập & tiện ích mở rộng") | `LoginItems` `Localizable.loctable` |
| Terminal menu item | Secure Keyboard Entry | Nhập dùng Bàn phím An Toàn | `Terminal.app` `MainMenu.loctable` `511.title` |

The three names in bold were changed in `SystemPanes.json` (the macOS 15 to 26 entry carries the macOS 27.2 spelling
of Login Items & Extensions). Deep links: the pane bundles of macOS 12.7.6 have the IDs the links name
(`com.apple.preference.security`, `com.apple.preference.keyboard`, `com.apple.preferences.users`) and list the anchors
`Privacy_Accessibility`, `Privacy_ListenEvent`, `Privacy`, `InputSources` and `Text`; on macOS 27.2 the extensions
have the IDs the links name (`com.apple.Keyboard-Settings.extension`, `com.apple.LoginItems-Settings.extension`) and
the Privacy & Security extension still lists `Privacy_Accessibility` and `Privacy_ListenEvent`. Where each link
actually lands is the on-screen check.

Still open: section 10.1 on both VMs (names as displayed, deep links, screenshots; the Monterey run needs the grant of
step 3), and macOS 13 to 26, which have no lab VM. Terminal shows the menu item in Vietnamese on a Vietnamese system,
while the app's Vietnamese secure-input hint quotes the English name; that copy belongs to the catalog owner.

## 11. Tap permission (`scripts/vm/tap-permission.sh`)

Specification: PLT-R701, PLT-R702, PLT-R705, PLT-R712, PLT-R731 (02-platform.md section 7). Question: which TCC
permission does the app's tap (active, key-down, session level, the parameters of `TapThread.swift`) need on a given
macOS, and which checks see a grant made while the app runs? Apple's answer (WWDC19 session 701): a listen-only tap
needs Input Monitoring, a modifying tap needs Accessibility; Apple DTS on the developer forums (threads 727984 and
720840): `CGPreflightPostEventAccess()` and `CGPreflightListenEventAccess()` keep the answer they had when the process
started. This check measures it on the lab VM.

```sh
scripts/vm/tap-permission.sh                       # {{app-slug}}-dev (macOS 27.2, SIP disabled)
scripts/vm/tap-permission.sh --keys 20 --output /Volumes/Data/tart/runs/<name>
scripts/vm/tap-permission.sh summarize --input <run folder>/tap-out/probe.jsonl
```

What it does, in the throwaway clone `<vm>-tap` (deleted at the end, like every lab clone):

1. Refuses to start while Safari runs on the host or another VM runs (section 5). Before any VM starts it compiles
   `scripts/vm/guest/tap-permission-probe.swift` on the host (`swiftc -O -target arm64-apple-macos12.0`), wraps it in
   an app bundle `TapProbe.app` (bundle ID: the development bundle ID plus `.tapprobe`, `LSUIElement`), signs the
   bundle and a copy of the binary (the typer) ad hoc, and never runs either on the host. A guest with SIP enabled is
   refused: `grant-tcc.sh` cannot write TCC there.
2. Copies the bundle, the typer, `grant-tcc.sh` and the script itself into the guest and runs
   `tap-permission.sh guest` through the tart guest agent (the logged-in session). The guest mode installs the probe in
   `~/Applications`, runs `tccutil reset All` for its bundle ID, grants the typer and the guest agent Accessibility
   and event posting, and starts the probe with `open`, so TCC sees the bundle and not the shell that started it.
3. Five phases, each marked in `probe.jsonl`, each followed by `--keys` presses of the X key typed by the typer:
   `fresh` (nothing granted), `accessibility-live` (the Accessibility row only, same process),
   `accessibility-relaunch` (the probe quit and started again), `input-monitoring-live` (Input Monitoring added, same
   process), `input-monitoring-relaunch`. Grants go through `grant-tcc.sh`, which restarts `tccd`, unlike the switch
   in System Settings; a process-level cache in CoreGraphics is not affected by either route.
4. Every second the probe appends one line: `AXIsProcessTrusted()`, `CGPreflightPostEventAccess()`,
   `CGPreflightListenEventAccess()`, whether its active tap is installed (it retries every second), whether a
   listen-only tap can be created now (the app's live Input Monitoring check), the key-downs its tap received from
   other processes and how many of its own posted key-downs (F19, marked) came back through it. Counts only, never a
   key (PLT-R901).

Run folder `VM_LAB_RUNS/<timestamp>-tap-permission/` (or `--output`): `tap-permission.log`, `guest.log`,
`summary.txt` (one row per phase: ax, post, listen, activeTap, listenOnlyNow, keys/typed, echoes/posted) and
`tap-out/` with `probe.jsonl`, `guest-summary.txt`, `system.txt`, the grant logs and `tcc-rows.txt` (the probe's TCC
rows at the end).

Self-tests: `python3 -I scripts/tests/test_tap_permission.py` (part of `scripts/tests/run.sh`) drives the host mode
with fake `tart`, `ssh`, `pgrep`, `swiftc` and `codesign`, the guest mode with a fake `sysctl` and fake system tools,
and `summarize` on a sample log; no VM starts and nothing touches TCC or posts a key on the host.

### 11.1 Results

Not run yet (W8-C, 2026-11-14): Safari was open on the host for the whole wait, so no VM was booted. Until a run
exists, the app follows Apple's documented behaviour (PLT-R701, PLT-R702): readiness is `AXIsProcessTrusted()`, the
Input Monitoring row appears only when the tap cannot be created with Accessibility granted, and the listen-only tap
is the live Input Monitoring check. What a run must record here: for each phase, whether the active tap was created
and received the typed keys, whether the probe's own posted keys came back (posting works after a live grant), and
which of the three checks changed without a relaunch.

Until this section has a result, the cause stated in PLT-R701 (the relaunch after the Input Monitoring change refreshed
the post preflight) is an inference, and Pa's checklist T2.2 on macOS 27.2 is the acceptance gate for feedback item 1:
remove the app from both Device Control and Data Access and Input Monitoring, open it again, switch on Device Control
and Data Access only, and confirm that screen 2 moves on within 1 s (or shows the Input Monitoring row with its own
button) and that typing works on screen 7 without opening the app again. Record the outcome here and update PLT-R702
with the phase that created the tap.

## 12. Upgrade test, channel switch and egress test (`scripts/vm/upgrade-test.sh`)

Specification: QA-R40, PLT-R1108, PLT-R906, PRD-R52, spec/02-platform.md sections 13.5 and 13.7,
[release.md](release.md) section 5 items 2 and 3 and the egress line of its pre-flight checklist. One command per
release candidate, on the notarized artefacts:

```sh
scripts/vm/upgrade-test.sh --previous dist/{{app-slug}}-1.0.1 --candidate dist/{{app-slug}}-1.1.0-beta.1
scripts/vm/upgrade-test.sh ... --no-egress --no-channel      # the upgrade test alone (about 20 minutes)
scripts/vm/upgrade-test.sh ... --sign                        # a candidate not in the published appcast yet
```

### 12.1 How the release build is pointed at a local appcast

The release build has no supported way to change its feed: `SUFeedURL` in `Info.plist` is
`https://<site host>/appcast.xml` (`Config/Sparkle.xcconfig`), `UpdaterConfiguration.refusal` refuses to start
Sparkle with any other value, and `UpdaterController` gives Sparkle no feed of its own (no `feedURLString(for:)`).
A defaults override of `SUFeedURL` would test a feed URL no user has, and the apps under test are never modified or
re-signed. So everything happens inside the VM, which is thrown away afterwards:

- the guest creates a throwaway certificate authority and a certificate for the site host, and trusts that authority
  in the VM's System keychain only (`sudo security add-trusted-cert -d`, which root may do in the lab image without a
  prompt; its private key never leaves the VM);
- `scripts/vm/guest/local-feed-server.py` serves the run's feed folder over HTTPS on `127.0.0.1` and `::1`, port
  443, and logs every request (`feed-requests.jsonl`: path, status, size, user agent);
- the VM's `/etc/hosts` maps the site host to both loopback addresses, so the build fetches its own, unchanged URLs
  (appcast, update archive, release-notes page) from that server;
- `/etc/resolver/<site host>` sends every other DNS query for the site host to the same server, which answers none
  of them. `/etc/hosts` covers only A and AAAA records: in run `20261122T214034Z-upgrade` the site's real HTTPS
  record (HTTP/3 with an address hint) made the build fetch the update archive from the production host over QUIC,
  past the local feed (the published archive has the same bytes, so the update still installed);
- both are removed for the production phase of the egress test.

The feed (`in/feed/` of the run folder, written by `upgrade-report.py feed`) holds the candidate's item, with the
candidate's channel (`beta` for `X.Y.Z-beta.N`, none for a stable release), the previous stable's item (older, so
never offered: no downgrade), and for the channel switch a beta-only probe item one build above the candidate,
which points at the candidate's archive and is offered but never installed. The candidate's EdDSA signature is the
published appcast's when that item lists the same build, version and length and the archive's SHA-256 equals
`SHA256SUMS`; the host verifies it with OpenSSL 3 against the previous app's `SUPublicEDKey` before any VM starts
(the key the installed app checks), and Sparkle checks it again inside the VM. A candidate that is not published
yet stops with exit 6, unless `--sign` asks Sparkle's `sign_update` for a signature (from `SPARKLE_SIGN_UPDATE` or
the copy `scripts/publish-release` keeps; the key stays in the login keychain). A call that does not finish within
60 seconds (a keychain prompt) stops that path instead of working around it.

Limits: the production host's real TLS certificate, CDN and phased rollout are not part of the upgrade itself (the
production phase of the egress test does reach the real host); the channel is switched through the settings store
between launches, not through the About pane's control.

### 12.2 What it does

On the host: the artefact checks above, the run folder `VM_LAB_RUNS/<UTC timestamp>-upgrade/` (or `--output`), and
the resource rule of section 3 as a gate: it waits, checking every 2 minutes for up to `--wait-idle` minutes
(default 240), until the load average is under 5, the memory pressure level under 4 (critical), at least 45 % of the
memory free, no other VM runs and no `xcodebuild` runs. It starts `watchdog.sh` from `--watchdog DIR` (default
`VM_LAB_ROOT/kv-ops`) beside the VM as `run-lab.sh` does, records its stops, and starts it again when it ends while
the VM runs (every lab script shares `watchdog.stop`; the restarts go to `watchdog-restarts.txt`). Then, in the throwaway clone `<vm>-upgrade` (4096 MB,
4 CPUs by default; deleted at the end), the guest half:

1. builds `upgrade-driver.swift` (accessibility, synthetic keys, event-tap list, relaunch watch), TestHost from this
   commit, and `upgrade-store.swift` twice: against the previous stable's `Packages/AppCore` (the commit in its
   `build-info.json`) and against this commit's;
2. starts the local feed (section 12.1);
3. installs the previous stable from its DMG into `/Applications` and records its signature and Gatekeeper verdict;
4. seeds, through the previous version's own `SettingsStore` (so the files are what a user of that version has):
   14 settings, 12 of them besides the update switches (D16 click-to-toggle stays unset: it would turn the status
   item into a mode switch), the channel of the candidate, word lists, per-app learned
   words, 5 per-app rules, 8 remembered per-app modes, 3 compatibility overrides and 50 macros
   (`scripts/vm/fixtures/upgrade-plan.json`), with onboarding finished;
5. grants Accessibility, Input Monitoring and event posting with `grant-tcc.sh` (the app's row carries its
   designated requirement, as a grant in System Settings does), launches the app and types `duyeetj` into TestHost
   (expected `duyệt`), then snapshots the settings folder, the defaults domain and the TCC rows;
6. forces an update check from the status menu, presses Sparkle's Install Update and Install and Relaunch, copies
   the settings folder and the defaults domain the moment the old process exits (before the new version can load
   or write them), then records the new process's start time, when its event tap is enabled (`CGGetEventTapList`,
   every 10 ms) and from when typing into TestHost gives `duyệt`, without any click in between (the field is found
   and focused before the relaunch; attempts repeat until one reads back right, and the result is when that
   attempt's first key was typed). It copies the
   settings folder again 0.5 seconds after that tap is enabled (at the latest 4 seconds after the start): the
   store has loaded the folder by then, so a migration has written, while a change of the new session's own per-app
   memory cannot have landed yet (written 5 seconds after the change, PLT-R392);
7. 15 seconds after the relaunch snapshots again, records the installed version, TCC rows, prompt processes and the
   app's windows, and reads each snapshot with the matching version's store;
8. channel switch: with the probe item in the feed, beta (the probe is offered; the offer is dismissed by closing
   Sparkle's window, since Sparkle 2.10 has no Remind Me Later button and Skip This Version would store a skipped
   version), stable (up to date: no beta build and nothing older), beta again;
9. egress: 10 minutes with the local feed and a forced check, then the mapping and the server are removed and 10
   minutes follow with the production feed and a forced check. `tcpdump` on the PKTAP interface (`-i pktap,all -k NP`:
   every TCP SYN and UDP datagram with the process that sent it, and the names of the DNS lookups mDNSResponder makes
   for the app), `nettop` (every open flow of every process, each second), `lsof` of the app and Sparkle's helpers
   (`Autoupdate`, `Updater`, each second) and `dscacheutil` for the site host (every 20 seconds) run throughout; the
   update itself is sampled too. `nettop` alone would miss a connection that opens and closes between two samples
   (seen in the lab on 2026-11-23), `tcpdump` does not.

### 12.3 Checks and evidence

`upgrade-report.py analyse` writes `result.json` (one entry per check: result, evidence, files) and `summary.txt`.
Verdict `PASS` only when every check passed; `FAIL` when one failed; `INCOMPLETE` when one could not run (a skipped
part, a guest step that stopped); `ABORTED` when the watchdog stopped the VM.

| Check | Passes when |
|---|---|
| `artefacts` | DMG and update archive equal `SHA256SUMS`, versions and builds match `build-info.json`, both apps carry the same `SUPublicEDKey`, the signature verifies |
| `previous-stable` | The DMG installed the previous version, Gatekeeper accepts it, typing works in it |
| `seeded` | At least 10 settings besides the update switches, per-app rules, remembered per-app modes, overrides and 50 macros, read back by the previous store |
| `sparkle-update` | Sparkle offered the candidate, the local feed served the update archive, Install and Relaunch was pressed |
| `version-after` | `/Applications` holds the candidate, the relaunched process logged the candidate's version and build, the designated requirement is unchanged |
| `settings-files` | The exit snapshot holds no file written after the candidate started (Autoupdate relaunches within milliseconds of the exit, before the copy ends, so the files' modification times decide), and every file of the snapshot taken once the candidate loaded the folder is byte-identical to it, or each difference is a migration the candidate's code explains (`MIGRATION_RULES` in `upgrade-report.py`, each citing its code); anything else fails. Until the snapshot 15 seconds after the relaunch, only `app-modes.json` may change, and only by use (the app focused after the relaunch moves to the front or is recorded as seen for the first time); every earlier entry keeps its rule and mode |
| `settings-content` | The candidate's store reads the same settings, per-app entries, overrides and macros right after loading as the previous store read at exit; fields new in the candidate read as not set; 15 seconds later every seeded and exit value is still there |
| `defaults-domain` | Every key of the app's defaults domain is equal, except the keys that change on each launch by design (`DEFAULTS_RULES`: the launch guard, the post-update self-check's version, Sparkle's check time) |
| `permissions` | The app's TCC rows are unchanged and allowed, the host reached a ready state, no permission transition, no prompt process, no TCC request of the candidate in its first 20 seconds answered by a consent prompt (`tccd` log, auth reason 2 or 9), and no window after the relaunch (the QA-R42 self-check would show the permission screen) |
| `tap-within-2s` | The new process's event tap is enabled at most 2 seconds after the process started |
| `typing-within-5s` | Keys typed into TestHost at most 5 seconds after the process started read back as `duyệt`: the time is the first key of the first attempt that reads back right (those keystrokes were composed correctly); the read-back time, 0.3 seconds after the last key, is in the evidence too |
| `egress-update` (advisory, outside the verdict) | Records what the download, the signature checks and the install reached; passes when that was only loopback (the local feed) and no other name was looked up |
| `channel-switch` | Beta offers the probe build, stable offers nothing, beta offers it again |
| `egress-local` | 10 minutes, a forced check, a connection to the local feed, no remote address but loopback and no DNS lookup of another name |
| `egress-production` | 10 minutes, a forced check, a connection to the site host, no remote address outside loopback and the addresses the VM resolved for the site host during the phase, and no DNS lookup of another name |

The allowed host is the site host of `scripts/brand.env` only (PLT-R906, 13.7: "only the allowed host"). The other
hosts of `scripts/url-hosts.allow` are identifiers or archive hosts for a choice Pa has not made (GitHub Releases);
an endpoint of the app or a helper outside the allowed set fails the check and is listed by address and process.
`com.apple.WebKit.Networking` flows (the release-notes view of Sparkle's window) count too.

A `settings-files`, `settings-content`, `defaults-domain` or `permissions` failure is a release blocker (PRD-R52):
open an `update-regression` issue with the run folder.

`egress-update` has failed in every run so far on one endpoint: while Sparkle's `Autoupdate` installs the update,
the system checks the revocation of the Developer ID certificate online (Apple's OCSP service: a lookup of
`ocsp2.g.aaplimg.com` in run `20261123T004514Z-upgrade`, a connection of `Autoupdate` to `17.253.61.142:443` in run
`20261123T020752Z-upgrade`). The app's own requests went only to the local feed. PLT-R906 names only the site host;
whether an operating-system revocation check counts as the app's egress is open for Pa, so the check stays advisory
and reports the endpoint instead of deciding.

Self-tests: `python3 -I scripts/tests/test_upgrade_test.py` (part of `scripts/tests/run.sh`): the artefact and
signature checks with a throwaway key, the feed, the `nettop`, `lsof` and `dscacheutil` parsers, the comparisons, the
verdict, and the host script with fake `tart`, `ssh`, `git`, OpenSSL and host-load tools; no VM starts.

### 12.4 Results

Recorded per release candidate (run folder, verdict, notable evidence):

| Date | Previous, candidate | Run folder | Verdict | Notes |
|---|---|---|---|---|
| 2026-11-23 | 1.0.1 to 1.1.0-beta.1 | `20261123T020752Z-upgrade` | PASS, every check (guest at `8f61053e`; analysis re-run with `ddee8f57`) | The first analysis, kept as `result-first-analysis.json`, failed `sparkle-update` and `egress-production` on two report bugs fixed in `ddee8f57` (the Install and Relaunch label read after the press; an inbound QUIC reply counted as an endpoint). Tap enabled 0.85 s after the relaunch, typing matched at 3.48 s, settings folder byte-identical (exit snapshot against the one the candidate loaded), store contents identical, defaults domain changed only in the three launch keys, TCC rows unchanged with no consent prompt, no window. Channel switch: beta offered the probe, stable nothing, beta the probe again. Egress: local phase only `[::1]:443`; production phase only the site host's addresses, over TCP and QUIC; advisory `egress-update` above |
| 2026-11-23 | 1.0.1 to 1.1.0-beta.1 | `20261123T035338Z-upgrade` | FAIL on `typing-within-5s` only (guest at `ddee8f57`) | Every other check passed (tap 1.82 s on a host swapping at 31 to 36 % free memory). One typing attempt, started 0.39 s after the relaunch and reading `duyệt` at 5.01 s, spent most of its time in harness steps on the loaded guest before its keys; the check now times the first key of the attempt that reads back right (`typingVerifiedLatencySeconds` keeps the read-back time) |
| 2026-11-23 | 1.0.1 to 1.1.0-beta.1 | `20261122T191432Z` to `20261123T004514Z-upgrade` | test faults, fixed | Development runs: the CA trust step, a menu title read through `plutil -extract`, the site's HTTPS DNS record (the archive came from the production host over HTTP/3, past the local feed), Sparkle's window without Remind Me Later. The update itself worked from the third run on |
