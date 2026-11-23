#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Guest half of scripts/vm/upgrade-test.sh: the release candidate checks of docs/runbooks/release.md section 5
# items 2 (upgrade test, QA-R40, PLT-R1108, spec/02-platform.md 13.5) and 3 (channel switch), and the network
# egress test of spec/02-platform.md 13.7, on the notarized release artefacts. Runs INSIDE the disposable macOS +
# Xcode VM through the tart guest agent (the logged-in GUI session); never on the host. It records evidence only:
# scripts/vm/upgrade-report.py on the host decides PASS or FAIL from the files this script writes.
#
# How the release build is pointed at a local appcast (docs/runbooks/vm-test-lab.md section 12): the build accepts
# only its Info.plist feed, https://<site host>/appcast.xml (UpdaterConfiguration), so this script maps the site host
# to the loopback addresses in the VM's /etc/hosts and serves the run's feed there over HTTPS, with a certificate of
# a throwaway CA that only this VM trusts (local-feed-server.py). The apps under test are never modified.
#
# Steps: build TestHost and the guest tools from the copied checkout; start the local feed; install the previous
# stable from its DMG into /Applications; seed settings, per-app rules and memory, overrides and 50 macros through the
# previous version's own SettingsStore (upgrade-store.swift); grant TCC with grant-tcc.sh; launch it and type in
# TestHost; force an update check from its menu and accept Sparkle's install; record the relaunch (upgrade-driver
# relaunch); snapshot every file and the defaults domain before and after; then the channel switch and the two
# 10-minute egress phases (local feed, production feed) with tcpdump (PKTAP), nettop and lsof sampling.
#
# Usage: upgrade-guest.sh --in DIR --out DIR   (from the checkout root, inside the VM only; it exits 3 on a real Mac)
# DIR of --in holds params.env, previous.dmg, prev-src/ and cand-src/ (AppCore and VietnameseEngine of the commits in
# the previous stable's and the candidate's build-info.json) and feed/ (appcast-upgrade.xml, appcast-channel.xml,
# download/, release-notes/), all written by upgrade-test.sh.
# Exit 0 when every step ran (not a verdict), 1 when a step failed and later steps were skipped.
set -uo pipefail

# Refuse to run anywhere but inside a virtual machine, before parsing arguments and before any side effect: this
# script installs apps, edits /etc/hosts and the System keychain's trust settings, uses sudo and launches the app.
[ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" = 1 ] || {
  echo "refusing: not inside a virtual machine" >&2
  exit 3
}

usage() {
  echo "usage: upgrade-guest.sh --in DIR --out DIR" >&2
  exit 2
}
in_dir=""
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --in) [ $# -ge 2 ] || usage; in_dir="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; out="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$in_dir" ] && [ -n "$out" ] || usage
[ -f "$in_dir/params.env" ] || { echo "no params.env in $in_dir" >&2; exit 2; }

mkdir -p "$out/snapshots" "$out/evidence" "$out/egress" "$out/logs"
summary="$out/summary.txt"
: >"$summary"
steps="$out/steps.tsv"
: >"$steps"
note() { echo "$*" | tee -a "$summary"; }
current_step=""
step() {
  current_step="$1"
  printf '%s\tstart\t%s\n' "$(date +%s)" "$1" >>"$steps"
  note "== $1"
}
step_ok() { printf '%s\tok\t%s\n' "$(date +%s)" "$current_step" >>"$steps"; }
failed=0
stop() {
  printf '%s\tfail\t%s\t%s\n' "$(date +%s)" "$current_step" "$*" >>"$steps"
  note "STOPPED at '$current_step': $*"
  failed=1
  finish
}

# shellcheck source=scripts/lib/common.sh
. scripts/lib/common.sh
load_brand
# shellcheck source=/dev/null
. "$in_dir/params.env"
valid() { printf '%s' "$2" | grep -Eq "$1"; }
valid '^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$' "${PREV_VERSION:-}" || usage
valid '^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$' "${CAND_VERSION:-}" || usage
valid '^[0-9]+$' "${PREV_BUILD:-}" || usage
valid '^[0-9]+$' "${CAND_BUILD:-}" || usage
valid '^[0-9]+$' "${PROBE_BUILD:-}" || usage
valid '^(stable|beta)$' "${SEED_CHANNEL:-}" || usage
valid '^[0-9]+$' "${EGRESS_MINUTES:-}" || usage
valid '^[01]$' "${RUN_CHANNEL:-}" || usage
valid '^[01]$' "${RUN_EGRESS:-}" || usage

app="/Applications/$APP_DISPLAY_NAME.app"
exe="$app/Contents/MacOS/$APP_DISPLAY_NAME"
bundle="$APP_BUNDLE_ID_RELEASE"
support="$HOME/Library/Application Support/$APP_STORAGE_FOLDER"
app_logs="$HOME/Library/Logs/$APP_STORAGE_FOLDER"
testhost_bundle="$APP_BUNDLE_ID_DEV.testhost"
testhost_app="$HOME/Applications/TestHost.app"
field="testhost.native.textField"
reset_id="testhost.resetFields"
# Telex keys of testhost.native.telex (compat/scenarios); the seeded settings keep Telex (D1 unset).
keys="duyeetj"
expect="duyệt"
feed="$in_dir/feed"
tools="/tmp/upgrade-tools"
# Capture buffer of the egress samplers and the kernel's limit for it (16 MiB, the largest debug.bpf_maxbufsize
# takes); snapshot length in bytes.
TCPDUMP_BUFFER_KIB=16384
BPF_MAX_BUFFER_BYTES=16777216
TCPDUMP_SNAPLEN=768
driver="$tools/upgrade-driver"
tls="/tmp/upgrade-tls"
hosts_backup="/tmp/upgrade-hosts.orig"
mkdir -p "$tools"
log_start="$(date '+%Y-%m-%d %H:%M:%S')"

hosts_mapped=0
finish() {
  # Evidence the host needs even after a failure; the VM is thrown away afterwards.
  sampler_stop 2>/dev/null
  cp "$app_logs/diagnostics.jsonl" "$out/logs/app-diagnostics.jsonl" 2>/dev/null
  # /usr/bin/log: scripts/lib/common.sh defines a shell function named log.
  # Compact timestamps carry no zone: UTC, and a first line that says so (the host places TCC requests in time).
  /usr/bin/log show --start "$log_start" --style compact --timezone UTC \
    --predicate 'subsystem BEGINSWITH "org.sparkle-project"' >"$out/logs/sparkle.log" 2>&1
  {
    echo "#timezone=UTC"
    /usr/bin/log show --start "$log_start" --style compact --timezone UTC --predicate 'process == "tccd"'
    echo "#exit=$?"
  } >"$out/logs/tccd.log" 2>&1
  screencapture -x "$out/evidence/screen-final.png" 2>/dev/null
  restore_hosts
  feed_stop
  printf '%s\tend\t%s\n' "$(date +%s)" "failed=$failed" >>"$steps"
  if [ "$failed" = 0 ]; then note "GUEST: every step ran"; exit 0; fi
  note "GUEST: stopped early"
  exit 1
}

# --- Helpers ------------------------------------------------------------------------------------------------
json_field() { # json_field <file> <key>: one top-level value of a JSON object, empty when absent
  /usr/bin/python3 -I -c 'import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
value = data.get(sys.argv[2]) if isinstance(data, dict) else None
print("" if value is None else value)' "$1" "$2" 2>/dev/null
}
strings_value() { # strings_value <file.strings> <key>: one localized value, empty when absent
  # Not `plutil -extract`: it reads the dots of a key such as menu.checkForUpdates as a key path.
  [ -f "$1" ] || return 0
  plutil -convert json -o - "$1" 2>/dev/null | /usr/bin/python3 -I -c 'import json, sys
print(json.load(sys.stdin).get(sys.argv[1], ""))' "$2" 2>/dev/null || true
}
# Titles of one Sparkle string in every localization the app may show (its UI follows the macOS language).
sparkle_titles() {
  local key="$1" dir="$app/Contents/Frameworks/Sparkle.framework/Resources" lang value
  printf '%s\n' "$key"
  for lang in Base en vi; do
    value="$(strings_value "$dir/$lang.lproj/Sparkle.strings" "$key")"
    [ -z "$value" ] || printf '%s\n' "$value"
  done
}
app_pid() {
  "$driver" processes --executable "$exe" 2>/dev/null | /usr/bin/python3 -I -c 'import json, sys
found = json.load(sys.stdin)
print(found[-1]["pid"] if found else "")' 2>/dev/null
}
tap_enabled() { # tap_enabled <pid>: the process has an enabled event tap (CGGetEventTapList)
  "$driver" taps 2>/dev/null | /usr/bin/python3 -I -c 'import json, sys
pid = int(sys.argv[1])
sys.exit(0 if any(tap["pid"] == pid and tap["enabled"] for tap in json.load(sys.stdin)) else 1)' "$1"
}
wait_tap() { # wait_tap <seconds>: the running app's event tap is enabled
  local deadline=$(($(date +%s) + $1)) pid
  while [ "$(date +%s)" -lt "$deadline" ]; do
    pid="$(app_pid)"
    if [ -n "$pid" ] && tap_enabled "$pid"; then return 0; fi
    sleep 0.5
  done
  return 1
}
launch_app() {
  open -a "$app" || return 1
  wait_tap 30
}
quit_app() { "$driver" quit "$bundle" --timeout 30 >>"$out/logs/quit.log" 2>&1; }
snapshot() { # snapshot <name>: the settings folder and the defaults domain
  rm -rf "$out/snapshots/$1"
  if [ -d "$support" ]; then cp -R "$support" "$out/snapshots/$1"; else mkdir -p "$out/snapshots/$1"; fi
  defaults export "$bundle" "$out/snapshots/defaults-$1.plist" 2>/dev/null || true
  tcc_rows "$out/snapshots/tcc-$1.txt"
}
tcc_rows() {
  # shellcheck disable=SC2024 # the evidence file belongs to this user on purpose
  sudo -n /usr/bin/sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "SELECT service, client, client_type, auth_value, auth_reason, hex(csreq) FROM access WHERE client = '$bundle' ORDER BY service;" \
    >"$1" 2>&1
}
app_identity() { # app_identity <file>: version, build and signature of the installed app
  {
    echo "version=$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
    echo "build=$(defaults read "$app/Contents/Info" CFBundleVersion 2>/dev/null)"
    echo "designated=$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')"
    codesign -dv "$app" 2>&1 | grep -E '^(Authority|TeamIdentifier|Identifier|Timestamp|CodeDirectory)' || true
    echo "spctl=$(spctl -a -vv "$app" 2>&1 | tr '\n' ' ')"
    echo "running=$(ps -o pid=,lstart=,comm= -p "$(app_pid)" 2>/dev/null | tr -s ' ')"
  } >"$1"
}

# --- Egress sampling (13.7): tcpdump (PKTAP), nettop and lsof of the app and Sparkle's helpers ---------------------
sampler_stop() {
  local file
  for file in /tmp/upgrade-tcpdump.pid /tmp/upgrade-nettop.pid /tmp/upgrade-lsof.pid /tmp/upgrade-dns.pid; do
    [ -f "$file" ] || continue
    sudo -n kill "$(cat "$file")" 2>/dev/null || kill "$(cat "$file")" 2>/dev/null
    sudo -n rm -f "$file"
  done
}
sampler_start() { # sampler_start <phase> [light]: light = tcpdump only, for the update, whose relaunch is timed
  local phase="$1" mode="${2:-full}" dir="$out/egress"
  sampler_stop
  printf '%s\n' "$(date +%s)" >"$dir/$phase-started"
  # Every TCP SYN (IPv4 and IPv6) and UDP datagram with the process that sent it (PKTAP metadata, -k NP), and
  # the names of DNS lookups (mDNSResponder's packets carry the app as the effective process). nettop misses a
  # connection that opens and closes between two samples; this does not.
  # shellcheck disable=SC2024 # the samples belong to this user on purpose; only the samplers need root
  # PKTAP filters in user space: every packet of every interface crosses the capture buffer, and a burst of system
  # downloads overflowed the default one (14,655 drops in a local phase on 2026-11-23). Hence the buffer of
  # TCPDUMP_BUFFER_KIB (debug.bpf_maxbufsize is raised in step 1) and a snapshot of TCPDUMP_SNAPLEN bytes, enough
  # for the headers and a DNS answer; the drop count is in <phase>-tcpdump.err and the host checks it.
  sudo -n /bin/sh -c 'echo $$ > /tmp/upgrade-tcpdump.pid
    exec /usr/sbin/tcpdump -i pktap,all -k NP -n -l -tt -B "$2" -s "$3" "$1"' \
    sh "(tcp and tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0) or (ip6 and tcp and (ip6[53] & 0x12) == 0x02) or (udp and not port 5353)" \
    "$TCPDUMP_BUFFER_KIB" "$TCPDUMP_SNAPLEN" >"$dir/$phase-tcpdump.txt" 2>"$dir/$phase-tcpdump.err" &
  if [ "$mode" = light ]; then
    sleep 2
    return 0
  fi
  # shellcheck disable=SC2024
  sudo -n /bin/sh -c 'echo $$ > /tmp/upgrade-nettop.pid; exec /usr/bin/nettop -L 0 -s 1 -n -x' \
    >"$dir/$phase-nettop.csv" 2>"$dir/$phase-nettop.err" &
  # shellcheck disable=SC2024
  sudo -n /bin/sh -c 'echo $$ > /tmp/upgrade-lsof.pid
    while :; do echo "#t $(date +%s)"; /usr/sbin/lsof -nP -a -i -c "$1" -c Autoupdate -c Updater -F cpPn; sleep 1; done' \
    sh "$APP_DISPLAY_NAME" >"$dir/$phase-lsof.txt" 2>/dev/null &
  /bin/sh -c 'echo $$ > /tmp/upgrade-dns.pid
    while :; do echo "#t $(date +%s)"; /usr/bin/dscacheutil -q host -a name "$1"; sleep 20; done' \
    sh "$APP_SITE_HOST" >"$dir/$phase-dns.txt" 2>&1 &
  sleep 2
}

# --- Local feed ---------------------------------------------------------------------------------------------
feed_stop() {
  [ -f /tmp/upgrade-feed.pid ] || return 0
  sudo -n kill "$(cat /tmp/upgrade-feed.pid)" 2>/dev/null
  sudo -n rm -f /tmp/upgrade-feed.pid
}
# /etc/hosts answers A and AAAA only; /etc/resolver/<site host> sends every other query for the host (the HTTPS
# record with its h3 and address hints above all) to the feed server's DNS, which answers none of them.
map_hosts() {
  sudo -n cp /etc/hosts "$hosts_backup" || return 1
  printf '127.0.0.1 %s\n::1 %s\n' "$APP_SITE_HOST" "$APP_SITE_HOST" | sudo -n tee -a /etc/hosts >/dev/null || return 1
  hosts_mapped=1
  sudo -n mkdir -p /etc/resolver || return 1
  printf 'nameserver 127.0.0.1\n' | sudo -n tee "/etc/resolver/$APP_SITE_HOST" >/dev/null || return 1
  flush_dns
}
restore_hosts() {
  [ "$hosts_mapped" = 1 ] || return 0
  sudo -n cp "$hosts_backup" /etc/hosts && sudo -n rm -f "/etc/resolver/$APP_SITE_HOST" && hosts_mapped=0
  flush_dns
}
flush_dns() {
  sudo -n dscacheutil -flushcache 2>/dev/null
  sudo -n killall -HUP mDNSResponder 2>/dev/null
  sleep 1
}
use_appcast() { cp "$feed/$1" "$feed/appcast.xml.tmp" && mv "$feed/appcast.xml.tmp" "$feed/appcast.xml"; }

# Forced update check from the status menu, then the first Sparkle window: Install Update (pressed only when asked;
# otherwise the offer is dismissed by closing its window, which stores no skipped version) or OK. Writes
# <name>-menu.json, <name>-window.json and <name>-press.json.
forced_check() { # forced_check <name> <install|dismiss> [timeout]
  local name="$1" mode="$2" timeout="${3:-90}" found
  "$driver" activate "$testhost_bundle" >/dev/null 2>&1
  run_driver "$out/evidence/$name-menu.json" menu "$bundle" "${menu_title_args[@]}" || return 1
  run_driver "$out/evidence/$name-find.json" press "$bundle" "${offer_or_ok_args[@]}" --find-only \
    --timeout "$timeout" --dump "$out/evidence/$name-window.json" || return 1
  screencapture -x "$out/evidence/$name.png" 2>/dev/null
  found="$(json_field "$out/evidence/$name-find.json" found)"
  if grep -qxF -- "$found" <<<"$install_titles"; then
    if [ "$mode" = install ]; then
      run_driver "$out/evidence/$name-press.json" press "$bundle" "${install_args[@]}" --timeout 10
    else
      run_driver "$out/evidence/$name-press.json" press "$bundle" "${install_args[@]}" --close-window --timeout 10
    fi
  else
    run_driver "$out/evidence/$name-press.json" press "$bundle" "${ok_args[@]}" --timeout 10
  fi
}
run_driver() { # run_driver <json file> <driver arguments...>
  local file="$1"
  shift
  "$driver" "$@" >"$file" 2>>"$out/logs/driver.log"
}

# --- 1. System ------------------------------------------------------------------------------------------------
step "system"
{
  sw_vers
  xcodebuild -version
  csrutil status
  /usr/bin/python3 --version
  defaults read com.apple.HIToolbox AppleSelectedInputSources
  cat /etc/hosts
} >"$out/system.txt" 2>&1
note "$(sw_vers -productVersion), $(xcodebuild -version | head -n 1), $(csrutil status | sed 's/.*: //')"
for key in NSAutomaticCapitalizationEnabled NSAutomaticDashSubstitutionEnabled NSAutomaticPeriodSubstitutionEnabled \
  NSAutomaticQuoteSubstitutionEnabled NSAutomaticSpellingCorrectionEnabled NSAutomaticTextCompletionEnabled; do
  defaults write -g "$key" -bool false
done
sudo -n mdutil -a -i off >/dev/null 2>&1
# Room for the egress capture (section 10): the default limit of a capture buffer is 512 KiB.
# shellcheck disable=SC2024 # the evidence file belongs to this user on purpose; only sysctl needs root
sudo -n sysctl -w "debug.bpf_maxbufsize=$BPF_MAX_BUFFER_BYTES" >>"$out/system.txt" 2>&1
sysctl debug.bpf_maxbufsize >>"$out/system.txt" 2>&1
step_ok

# --- 2. Local feed over HTTPS, site host mapped to loopback (first: it needs no build) -------------------------
step "local feed: throwaway CA trusted only in this VM, $APP_SITE_HOST mapped to loopback in /etc/hosts"
rm -rf "$tls"
mkdir -p "$tls"
cat >"$tls/openssl.cnf" <<EOF
[req]
distinguished_name = dn
[dn]
[ca]
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
[leaf]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:$APP_SITE_HOST
EOF
{
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 7 -keyout "$tls/ca.key" -out "$tls/ca.pem" \
    -subj "/CN=$APP_SLUG upgrade test CA (VM only)" -config "$tls/openssl.cnf" -extensions ca &&
    openssl req -new -newkey rsa:2048 -nodes -sha256 -keyout "$tls/leaf.key" -out "$tls/leaf.csr" \
      -subj "/CN=$APP_SITE_HOST" -config "$tls/openssl.cnf" &&
    openssl x509 -req -sha256 -days 7 -in "$tls/leaf.csr" -CA "$tls/ca.pem" -CAkey "$tls/ca.key" -CAcreateserial \
      -out "$tls/leaf.pem" -extfile "$tls/openssl.cnf" -extensions leaf
} >"$out/logs/tls.log" 2>&1 || stop "could not create the VM-only certificates (logs/tls.log)"
cp "$tls/ca.pem" "$out/evidence/vm-only-ca.pem"
# Admin trust settings: root may set them without a prompt in this image (checked on macOS 27.2); a
# `security authorizationdb write` first is refused (-60005) and not needed.
{
  sudo -n security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$tls/ca.pem" &&
    security verify-cert -c "$tls/leaf.pem" -p ssl -s "$APP_SITE_HOST"
} >>"$out/logs/tls.log" 2>&1 || stop "the VM-only CA is not trusted for $APP_SITE_HOST (logs/tls.log)"
use_appcast appcast-upgrade.xml || stop "no appcast-upgrade.xml in the feed"
: >"$out/feed-requests.jsonl"
# shellcheck disable=SC2024 # the server log belongs to this user on purpose
sudo -n /usr/bin/python3 -I scripts/vm/guest/local-feed-server.py --root "$feed" --cert "$tls/leaf.pem" \
  --key "$tls/leaf.key" --log "$out/feed-requests.jsonl" --dns-host "$APP_SITE_HOST" --pid-file /tmp/upgrade-feed.pid \
  >"$out/logs/feed-server.log" 2>&1 &
map_hosts || stop "could not map $APP_SITE_HOST in /etc/hosts"
ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$tls/ca.pem" "https://$APP_SITE_HOST/appcast.xml")"
  [ "$code" = 200 ] && { ok=1; break; }
  sleep 1
done
[ "$ok" = 1 ] || stop "the local feed does not answer on https://$APP_SITE_HOST/appcast.xml (logs/feed-server.log)"
{
  dscacheutil -q host -a name "$APP_SITE_HOST"
  scutil --dns | grep -A3 "domain   : $APP_SITE_HOST"
} >"$out/evidence/hosts-mapped.txt" 2>&1
grep -q "domain   : $APP_SITE_HOST" "$out/evidence/hosts-mapped.txt" ||
  stop "the resolver for $APP_SITE_HOST is not in use (evidence/hosts-mapped.txt)"
note "feed: https://$APP_SITE_HOST/appcast.xml served from this VM ($(grep -c '<item>' "$feed/appcast.xml") items)"
step_ok

# --- 3. Tools: TestHost, the driver, the store tool (previous and candidate AppCore) ---------------------------
step "build: upgrade-driver, TestHost and upgrade-store (AppCore of the previous stable's and the candidate's commits)"
xcrun swiftc -O -o "$driver" scripts/vm/guest/upgrade-driver.swift >"$out/logs/build-driver.log" 2>&1 ||
  stop "upgrade-driver.swift did not compile (logs/build-driver.log)"
xcodegen_bin="$(scripts/install-xcodegen.sh --prefer-system 2>>"$out/logs/build-testhost.log")" ||
  stop "XcodeGen is not available (logs/build-testhost.log)"
"$xcodegen_bin/xcodegen" generate >>"$out/logs/build-testhost.log" 2>&1 || stop "xcodegen generate failed"
xcodebuild -project App.xcodeproj -scheme TestHost -configuration Debug -derivedDataPath /tmp/upgrade-dd \
  -disableAutomaticPackageResolution ONLY_ACTIVE_ARCH=YES build >>"$out/logs/build-testhost.log" 2>&1 ||
  stop "TestHost did not build (logs/build-testhost.log)"
mkdir -p "$HOME/Applications"
rm -rf "$testhost_app"
ditto /tmp/upgrade-dd/Build/Products/Debug/TestHost.app "$testhost_app" || stop "could not install TestHost"
store_tool() { # store_tool <name> <AppCore path>: a package with upgrade-store.swift as its main file
  local dir="$tools/store-$1"
  mkdir -p "$dir/Sources"
  cp scripts/vm/guest/upgrade-store.swift "$dir/Sources/main.swift"
  cat >"$dir/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "UpgradeStore",
    platforms: [.macOS(.v12)],
    dependencies: [.package(path: "$2")],
    targets: [
        .executableTarget(
            name: "upgrade-store",
            dependencies: [
                .product(name: "SettingsStore", package: "AppCore"), .product(name: "AppModel", package: "AppCore"),
            ],
            path: "Sources", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
EOF
  swift build -c release --package-path "$dir" >"$out/logs/build-store-$1.log" 2>&1 || return 1
  printf '%s\n' "$dir/.build/release/upgrade-store"
}
prev_store="$(store_tool previous "$in_dir/prev-src/Packages/AppCore")" ||
  stop "upgrade-store did not build against the previous stable's AppCore (logs/build-store-previous.log)"
# The candidate's store as the shipped app has it: its own commit (build-info.json), not this checkout's.
cand_store="$(store_tool candidate "$in_dir/cand-src/Packages/AppCore")" ||
  stop "upgrade-store did not build against the candidate's AppCore (logs/build-store-candidate.log)"
note "built: upgrade-driver, TestHost ($testhost_bundle), upgrade-store x2"
step_ok

# --- 4. Previous stable from its DMG --------------------------------------------------------------------------
step "install the previous stable $PREV_VERSION from its DMG into /Applications"
mnt="$(mktemp -d /tmp/upgrade-dmg.XXXXXX)"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$in_dir/previous.dmg" >"$out/logs/dmg.log" 2>&1 ||
  stop "could not mount previous.dmg (logs/dmg.log)"
rm -rf "$app"
ditto "$mnt/$APP_DISPLAY_NAME.app" "$app" || stop "could not copy the app from the DMG"
hdiutil detach "$mnt" >>"$out/logs/dmg.log" 2>&1
app_identity "$out/evidence/app-before.txt"
installed="$(sed -n 's/^version=//p' "$out/evidence/app-before.txt")"
[ "$installed" = "$PREV_VERSION" ] || stop "the DMG installed version '$installed', expected $PREV_VERSION"
note "installed $app $installed ($(sed -n 's/^build=//p' "$out/evidence/app-before.txt"))"
menu_titles="$(printf '%s\n%s\n' \
  "$(strings_value "$app/Contents/Resources/en.lproj/Menu.strings" menu.checkForUpdates)" \
  "$(strings_value "$app/Contents/Resources/vi.lproj/Menu.strings" menu.checkForUpdates)")"
install_titles="$(sparkle_titles "Install Update")"
relaunch_titles="$(sparkle_titles "Install and Relaunch")"
ok_titles="$(sparkle_titles "OK")"
title_args=()
build_title_args() { # build_title_args <titles> <what>: --title arguments for the driver in title_args (bash 3.2)
  local line
  title_args=()
  while IFS= read -r line; do
    [ -z "$line" ] || title_args+=(--title "$line")
  done <<<"$1"
  # An empty array is "unbound" for bash 3.2 under set -u: stop with the reason instead.
  [ -n "$(printf '%s' "$1" | tr -d '[:space:]')" ] || stop "no localized title found for $2 in the installed app"
}
printf '%s\n' "$install_titles" >"$out/titles-install.txt"
build_title_args "$menu_titles" "the menu item Check for Updates"
menu_title_args=("${title_args[@]}")
build_title_args "$install_titles" "Sparkle's Install Update"
install_args=("${title_args[@]}")
build_title_args "$relaunch_titles" "Sparkle's Install and Relaunch"
relaunch_args=("${title_args[@]}")
build_title_args "$ok_titles" "Sparkle's OK"
ok_args=("${title_args[@]}")
build_title_args "$(printf '%s\n%s\n' "$install_titles" "$ok_titles")" "Sparkle's buttons"
offer_or_ok_args=("${title_args[@]}")
step_ok

# --- 5. Seed the settings through the previous version's own store -------------------------------------------------
step "seed: settings, word lists, per-app rules and memory, overrides, 50 macros (SettingsStore of $PREV_VERSION)"
"$prev_store" seed --dir "$support" --written-by "$PREV_VERSION" --plan "$PWD/scripts/vm/fixtures/upgrade-plan.json" \
  --channel "$SEED_CHANNEL" >"$out/seed.json" 2>"$out/logs/seed.log" || stop "seeding failed (logs/seed.log)"
snapshot seeded
note "seeded: $(tr -d '\n ' <"$out/seed.json" | cut -c1-200)"
step_ok

# --- 6. TCC ---------------------------------------------------------------------------------------------------------
step "TCC grants (grant-tcc.sh): the app, TestHost, the driver and the process that starts it"
agent_pid="$(pgrep -n -f tart-guest-agent || true)"
agent=""
[ -z "$agent_pid" ] || agent="$(ps -o comm= -p "$agent_pid")"
clients=(--bundle "$app" --bundle "$testhost_app" --binary "$driver" --binary /usr/libexec/sshd-keygen-wrapper)
if [ -n "$agent" ] && [ -x "$agent" ]; then clients+=(--binary "$agent"); fi
# shellcheck disable=SC2024 # the log belongs to this user on purpose
sudo -n bash scripts/vm/grant-tcc.sh "${clients[@]}" >"$out/logs/grant.log" 2>&1 || stop "grant-tcc.sh failed"
# screencapture runs from the guest agent: without Screen Recording its consent prompt would cover the windows the
# test reads and look like a permission prompt after the update.
if [ -n "$agent" ] && [ -x "$agent" ]; then
  # shellcheck disable=SC2024
  sudo -n bash scripts/vm/grant-tcc.sh --service kTCCServiceScreenCapture --binary "$agent" \
    >>"$out/logs/grant.log" 2>&1 || stop "grant-tcc.sh (Screen Recording for the guest agent) failed"
fi
tcc_rows "$out/snapshots/tcc-granted.txt"
note "$(grep -c . "$out/snapshots/tcc-granted.txt") TCC rows for $bundle"
step_ok

# --- 7. The previous stable running, typing in TestHost -------------------------------------------------------------
step "launch $PREV_VERSION and type in TestHost"
open -a "$testhost_app" || stop "TestHost did not open"
sleep 3
launch_app || stop "the previous stable did not enable its event tap within 30 s"
app_identity "$out/evidence/app-running-before.txt"
sleep 5
run_driver "$out/evidence/typing-before.json" type "$testhost_bundle" --field "$field" --keys "$keys" \
  --expect "$expect" --reset "$reset_id" --seconds 20 || stop "typing in TestHost does not work on $PREV_VERSION"
# TestHost stays frontmost; the app records it as seen (5 s debounce, PLT-R392) before the snapshot.
sleep 7
snapshot before
step_ok

# --- 8. Update through Sparkle -----------------------------------------------------------------------------------
step "update: forced check from the menu, Install Update, Install and Relaunch"
# tcpdump alone here: nettop and lsof each walk every process once a second and would slow the timed relaunch.
sampler_start update light
# With the cache empty, every name resolved during the install is looked up while tcpdump runs: the host allows the
# system's revocation check of the update's signature only to an address the capture saw resolved from Apple's OCSP
# names (a cached answer left such a connection without its lookup in run 20261123T020752Z-upgrade).
flush_dns
forced_check update-offer install 90 || stop "no update offered by the local feed (evidence/update-offer-*.json)"
run_driver "$out/evidence/update-ready-find.json" press "$bundle" "${relaunch_args[@]}" --find-only --timeout 240 \
  --dump "$out/evidence/update-ready-window.json" || stop "Sparkle never got ready to install"
screencapture -x "$out/evidence/update-ready.png" 2>/dev/null
old_pid="$(app_pid)"
[ -n "$old_pid" ] || stop "the previous stable is not running"
"$driver" activate "$testhost_bundle" >/dev/null 2>&1
"$driver" relaunch --executable "$exe" --old-pid "$old_pid" --snapshot-src "$support" \
  --snapshot-dst "$out/snapshots/at-exit" --loaded-snapshot-dst "$out/snapshots/loaded" --defaults-domain "$bundle" \
  --defaults-dst "$out/snapshots/defaults-at-exit.plist" --typing-bundle "$testhost_bundle" --field "$field" \
  --keys "$keys" --expect "$expect" --reset "$reset_id" --watch 30 --timeout 300 \
  >"$out/relaunch.json" 2>>"$out/logs/driver.log" &
watcher=$!
sleep 1
run_driver "$out/evidence/update-install-press.json" press "$bundle" "${relaunch_args[@]}" --timeout 20 ||
  stop "could not press Install and Relaunch"
wait "$watcher" || note "relaunch watcher exit $?"
tcc_rows "$out/snapshots/tcc-at-exit.txt"
# 15 s after the new start: past the 5 s app-modes debounce, nothing in the new session has been changed by the test.
started="$(json_field "$out/relaunch.json" newStartedAt)"
started="${started%.*}"
[ -n "$started" ] && while [ "$(date +%s)" -lt $((started + 15)) ]; do sleep 1; done
snapshot after
app_identity "$out/evidence/app-after.txt"
# The Accessibility and Input Monitoring prompts are shown by universalAccessAuthWarn; System Settings would open
# for a permission screen. Their windows, if any, are in the screenshot.
{
  pgrep -lx 'universalAccessAuthWarn|System Settings|UserNotificationCenter'
  echo "#exit=$?" # 0 found, 1 none: anything else means the list is not evidence
} >"$out/evidence/prompt-processes.txt" 2>&1
pgrep -x universalAccessAuthWarn >/dev/null 2>&1 && note "permission prompt process running after the update"
screencapture -x "$out/evidence/after-relaunch.png" 2>/dev/null
# PRD-R52: the first launch after an update shows nothing; the QA-R42 self-check would show the permission screen.
# A failed listing leaves no file: the host then cannot show "no window" and reports the check as not run.
run_driver "$out/evidence/app-windows-after.json" windows "$bundle" || {
  note "the window listing failed (logs/driver.log)"
  rm -f "$out/evidence/app-windows-after.json"
}
sampler_stop
printf '%s\n' "$(date +%s)" >"$out/egress/update-ended"
note "now: $(sed -n 's/^version=//p' "$out/evidence/app-after.txt") ($(sed -n 's/^build=//p' "$out/evidence/app-after.txt"))"
step_ok

# --- 8b. What each version's store reads (on copies: a load may write when it migrates) --------------------------
step "dumps: the seeded and exit snapshots read by $PREV_VERSION's store, the post-update one by $CAND_VERSION's"
mkdir -p "$out/dumps"
dump_with() { # dump_with <store tool> <snapshot> <name>
  local tmp
  tmp="$(mktemp -d /tmp/upgrade-dump.XXXXXX)"
  cp -R "$out/snapshots/$2" "$tmp/folder" &&
    "$1" dump --dir "$tmp/folder" >"$out/dumps/$3.json" 2>>"$out/logs/dump.log"
  local rc=$?
  rm -rf "$tmp"
  return $rc
}
dump_with "$prev_store" seeded seeded.previous || stop "dump of the seeded snapshot failed"
dump_with "$prev_store" at-exit at-exit.previous || stop "dump of the exit snapshot failed"
dump_with "$cand_store" loaded loaded.candidate || stop "dump of the loaded snapshot failed"
dump_with "$cand_store" after after.candidate || stop "dump of the post-update snapshot failed"
step_ok

# --- 9. Channel switch (release.md section 5 item 3): beta, stable, beta -----------------------------------------
if [ "$RUN_CHANNEL" = 1 ]; then
  step "channel switch: beta to stable and back, against a feed with a beta-only probe item $PROBE_BUILD"
  use_appcast appcast-channel.xml || stop "no appcast-channel.xml in the feed"
  # What Sparkle says when nothing is offered, in the localizations of the installed (candidate) app.
  sparkle_titles "You’re up to date!" >"$out/titles-uptodate.txt"
  : >"$out/channel.tsv"
  n=0
  for channel in beta stable beta; do
    n=$((n + 1))
    quit_app || stop "the app did not quit"
    "$cand_store" set-channel --dir "$support" --written-by "$CAND_VERSION" --channel "$channel" \
      >>"$out/logs/channel.log" 2>&1 || stop "set-channel $channel failed"
    channel_start="$(date +%s)"
    launch_app || stop "the app did not enable its tap after the channel change"
    sleep 3
    forced_check "channel-$n-$channel" dismiss 90 || stop "no Sparkle window after the forced check ($channel)"
    # n, channel, the button found, and when the step ran (the host counts update.updateFound in that window).
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$channel" \
      "$(json_field "$out/evidence/channel-$n-$channel-find.json" found)" "$channel_start" "$(date +%s)" \
      >>"$out/channel.tsv"
    sleep 2
  done
  snapshot after-channel
  step_ok
fi

# --- 10. Egress (13.7): 10 minutes on the local feed, 10 minutes on the production feed -----------------------------
egress_phase() { # egress_phase <local|production>: sampling starts before the launch, so it covers the start too
  local phase="$1" end
  quit_app || return 1
  sampler_start "$phase"
  end=$(($(date +%s) + EGRESS_MINUTES * 60))
  launch_app || return 1
  sleep 3
  forced_check "egress-$phase" dismiss 120 || note "egress $phase: no Sparkle window after the forced check"
  while [ "$(date +%s)" -lt "$end" ]; do sleep 5; done
  printf '%s\n' "$(date +%s)" >"$out/egress/$phase-ended"
  sampler_stop
}
if [ "$RUN_EGRESS" = 1 ]; then
  step "egress, local feed: $EGRESS_MINUTES minutes with a forced check"
  use_appcast appcast-upgrade.xml || stop "no appcast-upgrade.xml in the feed"
  egress_phase local || stop "the local egress phase did not run"
  step_ok
  step "egress, production feed: $EGRESS_MINUTES minutes with a forced check"
  restore_hosts
  feed_stop
  dscacheutil -q host -a name "$APP_SITE_HOST" >"$out/evidence/hosts-production.txt" 2>&1
  if grep -Eq 'ip(v6)?_address: (127\.|::1$)' "$out/evidence/hosts-production.txt"; then
    stop "$APP_SITE_HOST still resolves to loopback"
  fi
  egress_phase production || stop "the production egress phase did not run"
  step_ok
fi

finish
