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
   (`guest/smoke-guest.sh`, `guest/integration-guest.sh`, `grant-tcc.sh`) check `kern.hv_vmm_present` first and
   exit 3 on a real Mac, before they parse an argument or touch anything.
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
disabled, so `scripts/vm/grant-tcc.sh` grants TCC). How it works, the result of the first attempt and the manual
grant for an image with SIP enabled: [integration-suite.md](integration-suite.md) section 10. The runner plan:
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
