#!/bin/zsh
# Re-verify a previously built LatticeLens 1.0 local DMG without installing it.
# All mutable state remains in a project-local task scratch directory.
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
[[ $# -eq 1 && -d "$1" ]] || { print -u2 'usage: zsh Scripts/smoke_v1_local_dmg.sh <Release-1.0.0-local>'; exit 64; }
release="${1:A}"
case "$release" in "$root"/*) ;; *) print -u2 'release directory must remain below the project root'; exit 65 ;; esac

manifest="$release/manifest-v1.0.json"
dmg="$release/LatticeLens-1.0.0-local.dmg"
dsym_zip="$release/LatticeLens-1.0.0.dSYM.zip"
checksums="$release/SHA256SUMS.txt"
[[ -f "$manifest" && -f "$dmg" && -f "$dsym_zip" && -f "$checksums" ]] || { print -u2 'release is missing manifest, DMG, dSYM zip, or checksum manifest'; exit 65; }

jq -e '
  .schema_version == "latticelens-package-manifest-v1.0" and
  .artifact_class == "same_mac_local_ad_hoc" and
  .product_version == "1.0.0" and .build_number == 100 and
  .signature_class == "ad_hoc_local" and .developer_id == false and .notarized == false and
  .dmg_smoke == "passed" and
  (.build_input_tree_sha256 | test("^[0-9a-f]{64}$")) and
  (.artifacts.dmg.sha256 | test("^[0-9a-f]{64}$")) and
  (.artifacts.dsym.sha256 | test("^[0-9a-f]{64}$"))
' "$manifest" >/dev/null || { print -u2 'package manifest is malformed or overclaims the local artifact'; exit 65; }

expected_dmg_sha="$(jq -r '.artifacts.dmg.sha256 // empty' "$manifest")"
[[ "$expected_dmg_sha" =~ '^[0-9a-f]{64}$' ]] || { print -u2 'manifest has no valid DMG SHA-256'; exit 65; }
actual_dmg_sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"
[[ "$actual_dmg_sha" == "$expected_dmg_sha" ]] || { print -u2 'DMG SHA-256 mismatch'; exit 1; }
expected_dsym_sha="$(jq -r '.artifacts.dsym.sha256 // empty' "$manifest")"
actual_dsym_sha="$(shasum -a 256 "$dsym_zip" | awk '{print $1}')"
[[ "$actual_dsym_sha" == "$expected_dsym_sha" ]] || { print -u2 'dSYM ZIP SHA-256 mismatch'; exit 1; }
( cd "$release" && shasum -a 256 -c "${checksums:t}" ) >/dev/null || { print -u2 'SHA256SUMS verification failed'; exit 1; }

scratch="$(mktemp -d "$root/.codex-task-tmp-v5-dmg-smoke-XXXXXX")"
mount="$scratch/mount"
inspection="$scratch/inspection"
fixture_root="$scratch/fixture-store"
mounted=false
app_pid=""
cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then kill -TERM "$app_pid" 2>/dev/null || true; fi
  if [[ "$mounted" == true ]]; then hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach -force "$mount" >/dev/null 2>&1 || true; fi
  [[ -d "$scratch" ]] && find "$scratch" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' INT TERM

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || print ''; }
verify_app() {
  local app="$1" info executable binary
  info="$app/Contents/Info.plist"
  [[ -f "$info" && -s "$app/Contents/Resources/AppIcon.icns" ]] || return 1
  plutil -lint "$info" >/dev/null
  [[ "$(plist_value CFBundleShortVersionString "$info")" == '1.0.0' ]]
  [[ "$(plist_value CFBundleVersion "$info")" == '100' ]]
  [[ "$(plist_value CFBundleIdentifier "$info")" == 'org.latticelens.app' ]]
  executable="$(plist_value CFBundleExecutable "$info")"
  binary="$app/Contents/MacOS/$executable"
  [[ -x "$binary" ]]
  lipo "$binary" -verify_arch arm64 x86_64
  codesign --verify --deep --strict "$app"
}

mkdir -p "$mount" "$inspection" "$fixture_root"
hdiutil verify "$dmg"
hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null
mounted=true
mounted_app="$mount/LatticeLens.app"
verify_app "$mounted_app"
ditto "$mounted_app" "$inspection/LatticeLens.app"
verify_app "$inspection/LatticeLens.app"
binary="$inspection/LatticeLens.app/Contents/MacOS/$(plist_value CFBundleExecutable "$inspection/LatticeLens.app/Contents/Info.plist")"
LATTICELENS_USE_FIXTURES=1 LATTICELENS_TEST_STORE_ROOT="$fixture_root" \
  "$binary" -LatticeLensUseFixtures YES >"$scratch/app.log" 2>&1 &
app_pid="$!"
typeset -i elapsed=0
while (( elapsed < 3 )); do
  if ! kill -0 "$app_pid" 2>/dev/null; then
    print -u2 'fixture/no-network copied app exited before smoke threshold'
    tail -n 24 "$scratch/app.log" >&2 || true
    exit 1
  fi
  sleep 1
  (( elapsed += 1 ))
done
kill -TERM "$app_pid"
typeset -i shutdown=0
while kill -0 "$app_pid" 2>/dev/null && (( shutdown < 8 )); do sleep 1; (( shutdown += 1 )); done
if kill -0 "$app_pid" 2>/dev/null; then print -u2 'fixture/no-network copied app did not terminate'; exit 1; fi
app_pid=""
hdiutil detach "$mount" >/dev/null
mounted=false
print "PASS mounted DMG version/icon/architecture/signature check and project-local fixture/no-network copy-launch smoke ($actual_dmg_sha)"
