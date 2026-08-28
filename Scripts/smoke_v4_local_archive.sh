#!/bin/zsh
# Non-destructive same-Mac fixture launch and rollback smoke for a v4 archive.
# It never opens the user's library: the launched app is forced into the
# in-memory, process-local fixture dependency graph before its AppViewModel is
# constructed.  The inspection copy and all output stay below project_root.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
archive_dir="${1:-}"
keep_evidence=false

if [[ -z "$archive_dir" || "$archive_dir" == "-h" || "$archive_dir" == "--help" ]]; then
  print "usage: zsh Scripts/smoke_v4_local_archive.sh <project-local-release-dir> [--keep-evidence]"
  exit 2
fi
[[ $# -le 2 ]] || { print -u2 "too many arguments"; exit 2; }
if [[ "${2:-}" == "--keep-evidence" ]]; then
  keep_evidence=true
elif [[ -n "${2:-}" ]]; then
  print -u2 "unknown option: $2"
  exit 2
fi

case "$archive_dir" in
  "$project_root"/*) ;;
  *) print -u2 "archive directory must stay below project root"; exit 2 ;;
esac

manifest="$archive_dir/manifest-v4.json"
payload="$archive_dir/LatticeLens-v4-local.zip"
[[ -f "$manifest" && -f "$payload" ]] || { print -u2 "missing manifest or payload"; exit 2; }

expected_sha="$(jq -r '.payload.sha256 // empty' "$manifest")"
[[ "$expected_sha" =~ '^[0-9a-f]{64}$' ]] || { print -u2 "manifest payload SHA-256 is invalid"; exit 2; }
actual_sha="$(/usr/bin/shasum -a 256 "$payload" | /usr/bin/awk '{print $1}')"
[[ "$actual_sha" == "$expected_sha" ]] || { print -u2 "payload hash mismatch"; exit 1; }

scratch="$(/usr/bin/mktemp -d "$project_root/.codex-task-tmp-v4-archive-smoke-XXXXXX")"
inspection_root="$scratch/inspection"
fixture_root="$scratch/fixture-store"
app_pid=""

cleanup() {
  if [[ -n "$app_pid" ]] && /bin/kill -0 "$app_pid" 2>/dev/null; then
    /bin/kill -TERM "$app_pid" 2>/dev/null || true
    /bin/sleep 1
  fi
  if $keep_evidence; then
    print -u2 "KEEP_EVIDENCE=$scratch"
    return 0
  fi
  [[ -d "$scratch" ]] || return 0
  /usr/bin/find "$scratch" -depth -type f -exec /bin/unlink {} ';'
  /usr/bin/find "$scratch" -depth -type l -exec /bin/unlink {} ';'
  /usr/bin/find "$scratch" -depth -type d -exec /bin/rmdir {} '+' 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' INT TERM

/bin/mkdir -p "$inspection_root" "$fixture_root"
/usr/bin/ditto -x -k "$payload" "$inspection_root"
app="$inspection_root/LatticeLens.app"
info_plist="$app/Contents/Info.plist"
[[ -d "$app" && -f "$info_plist" ]] || { print -u2 "payload did not contain LatticeLens.app"; exit 1; }
/usr/bin/plutil -lint "$info_plist" >/dev/null
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
binary="$app/Contents/MacOS/$executable"
[[ -x "$binary" ]] || { print -u2 "archive executable missing: $executable"; exit 1; }

# Fixture flag + fixture environment jointly select InMemoryLibraryStore,
# AppFixtureTransport, fixture model discovery and UIFixtureKeychainStore.
LATTICELENS_USE_FIXTURES=1 \
LATTICELENS_TEST_STORE_ROOT="$fixture_root" \
"$binary" -LatticeLensUseFixtures YES >"$scratch/app.log" 2>&1 &
app_pid="$!"

typeset -i launch_seconds=0
while (( launch_seconds < 3 )); do
  if ! /bin/kill -0 "$app_pid" 2>/dev/null; then
    print -u2 "fixture archive app exited before launch confirmation"
    tail -n 24 "$scratch/app.log" >&2 || true
    exit 1
  fi
  /bin/sleep 1
  (( launch_seconds += 1 ))
done

# The rollback is non-destructive by construction: terminate only the fixture
# app just launched above, then let cleanup remove the extracted inspection
# copy. No Application Support, Keychain, PDFs, prior archive or active store
# path is ever targeted.
/bin/kill -TERM "$app_pid"
typeset -i shutdown_seconds=0
while /bin/kill -0 "$app_pid" 2>/dev/null && (( shutdown_seconds < 8 )); do
  /bin/sleep 1
  (( shutdown_seconds += 1 ))
done
if /bin/kill -0 "$app_pid" 2>/dev/null; then
  print -u2 "fixture archive app did not terminate after TERM"
  exit 1
fi
app_pid=""

print "PASS same-Mac fixture archive launch (≥3 s) and non-destructive rollback (payload SHA-256: $actual_sha)"
