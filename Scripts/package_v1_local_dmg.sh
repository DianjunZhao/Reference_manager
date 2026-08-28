#!/bin/zsh
# Build the local-only LatticeLens 1.0 DMG.  This is deliberately a
# pre-promotion step: the validation input must prove every non-packaging
# automated prerequisite, while this script itself establishes the DMG gate.
# It never writes to /Applications, Application Support, Keychain, or a user
# library.
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
packager_exec_path="${PATH:-}"
[[ -n "$packager_exec_path" && -x /usr/bin/env ]] || {
  print -u2 'packager environment has no usable command path'
  exit 66
}

usage() {
  print -u2 'usage: zsh Scripts/package_v1_local_dmg.sh <prepackage-validation-v5.json> <current-benchmark-v5.json>'
  exit 64
}

[[ $# -eq 2 && -f "$1" && -f "$2" ]] || usage
validation="${1:A}"
benchmark_evidence="${2:A}"
case "$validation" in
  "$root"/*) ;;
  *) print -u2 'validation ledger must be below the project root'; exit 65 ;;
esac
case "$benchmark_evidence" in
  "$root"/*) ;;
  *) print -u2 'benchmark evidence must be below the project root'; exit 65 ;;
esac
[[ "$benchmark_evidence" != "$validation" ]] || {
  print -u2 'benchmark evidence must be a separate artifact, not the validation ledger'
  exit 65
}
[[ ! -L "$validation" ]] || {
  print -u2 'refusing package: prepackage validation must not be a symlink'
  exit 65
}

# Requiring dmg_smoke=true here would be circular.  All other automated gates
# that can be proven before packaging must be true; manual install/VoiceOver
# evidence is intentionally recorded only after a mounted artifact exists.
required_gates=(
  swiftpm actual_swiftdata_benchmark swiftpm_release xcode_build_analyze
  xcode_unit ui_normal ui_large_scroll_accessibility typed_store
  migration_backup_rollback physics_validator radar compare notebook bundle
  icon_version_resources
)
for gate in "${required_gates[@]}"; do
  jq -e --arg gate "$gate" '.mandatory[$gate] == true' "$validation" >/dev/null || {
    print -u2 "refusing package: prepackage gate is not PASS: $gate"
    exit 65
  }
done

[[ "$(jq -r '.schema_version // empty' "$validation")" == 'latticelens-prepackage-v5' ]] || {
  print -u2 'refusing package: validation schema is not latticelens-prepackage-v5'
  exit 65
}
[[ "$(jq -r '.prepackage_eligible // false' "$validation")" == 'true' ]] || {
  print -u2 'refusing package: validation is not eligible for packaging'
  exit 65
}
[[ "$(jq -r '.product_version // empty' "$validation")" == '1.0.0' ]] || {
  print -u2 'refusing package: validation product version is not 1.0.0'
  exit 65
}
[[ "$(jq -r '.build_number // empty' "$validation")" == '100' ]] || {
  print -u2 'refusing package: validation build number is not 100'
  exit 65
}
expected_build_input_tree_sha256="$(jq -r '.build_input_tree_sha256 // empty' "$validation")"
[[ "$expected_build_input_tree_sha256" =~ '^[0-9a-f]{64}$' ]] || {
  print -u2 'refusing package: prepackage validation has no valid build-input SHA-256'
  exit 65
}
[[ ! -L "$benchmark_evidence" ]] || {
  print -u2 'refusing package: benchmark evidence must not be a symlink'
  exit 65
}
jq -e '
  .authors == 2000 and .papers == 20000 and .links == 100000 and .chunks == 10000 and
  .disk_backed.backup_verified == true and
  .warm_search_p95_ms <= 250 and .disk_backed.cold_open_p95_ms <= 5000 and .single_row_mutation_p95_ms <= 100 and
  .v7_active_domain.backup_verified == true and .v7_active_domain.warm_search_p95_ms <= 250 and
  .v7_active_domain.cold_open_p95_ms <= 5000 and .v7_active_domain.single_row_mutation_p95_ms <= 100 and
  .v9_final_typed.authors == 2000 and .v9_final_typed.papers == 20000 and
  .v9_final_typed.links == 100000 and .v9_final_typed.chunks == 10000 and
  .v9_final_typed.full_text_documents == 100 and .v9_final_typed.radar_events == 500 and
  .v9_final_typed.user_annotations == 200 and .v9_final_typed.tags == 100 and .v9_final_typed.collections == 100 and
  .v9_final_typed.backup_verified == true and .v9_final_typed.warm_search_result_count == 100 and
  .v9_final_typed.warm_search_p95_ms <= 250 and .v9_final_typed.cold_open_p95_ms <= 5000 and
  .v9_final_typed.single_row_mutation_p95_ms <= 100
' "$benchmark_evidence" >/dev/null || {
  print -u2 'refusing package: benchmark evidence is malformed or over threshold'
  exit 65
}

out="$root/Release-1.0.0-local"
[[ ! -e "$out" ]] || { print -u2 "refusing to overwrite existing output: $out"; exit 66; }

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
scratch="$(mktemp -d "$root/.codex-task-tmp-v5-package-${run_id}-XXXXXX")"
pending="$scratch/Release-1.0.0-local"
mount="$scratch/mounted-dmg"
fixture_root="$scratch/fixture-store"
inspection_root="$scratch/inspection"
mounted=false
app_pid=""

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill -TERM "$app_pid" 2>/dev/null || true
    sleep 1
  fi
  if [[ "$mounted" == true ]]; then
    hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach -force "$mount" >/dev/null 2>&1 || true
  fi
  [[ -d "$scratch" ]] && find "$scratch" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' INT TERM

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || print ''
}

verify_app() {
  local app="$1" info executable binary expected_version expected_build
  expected_version="$2"
  expected_build="$3"
  info="$app/Contents/Info.plist"
  [[ -d "$app" && -f "$info" && -s "$app/Contents/Resources/AppIcon.icns" ]] || {
    print -u2 "app resources are incomplete: $app"
    return 1
  }
  plutil -lint "$info" >/dev/null
  [[ "$(plist_value CFBundleShortVersionString "$info")" == "$expected_version" ]] || return 1
  [[ "$(plist_value CFBundleVersion "$info")" == "$expected_build" ]] || return 1
  [[ "$(plist_value CFBundleIdentifier "$info")" == 'org.latticelens.app' ]] || return 1
  executable="$(plist_value CFBundleExecutable "$info")"
  binary="$app/Contents/MacOS/$executable"
  [[ -x "$binary" ]] || return 1
  lipo "$binary" -verify_arch arm64 x86_64
  [[ "${4:-require_signature}" != 'require_signature' ]] || codesign --verify --deep --strict "$app"
}

launch_fixture_smoke() {
  local app="$1" log="$2" binary
  binary="$app/Contents/MacOS/$(plist_value CFBundleExecutable "$app/Contents/Info.plist")"
  mkdir -p "$fixture_root"
  LATTICELENS_USE_FIXTURES=1 LATTICELENS_TEST_STORE_ROOT="$fixture_root" \
    "$binary" -LatticeLensUseFixtures YES >"$log" 2>&1 &
  app_pid="$!"
  local -i elapsed=0
  while (( elapsed < 3 )); do
    if ! kill -0 "$app_pid" 2>/dev/null; then
      print -u2 'fixture/no-network app exited before the three-second smoke threshold'
      tail -n 24 "$log" >&2 || true
      return 1
    fi
    sleep 1
    (( elapsed += 1 ))
  done
  kill -TERM "$app_pid"
  local -i shutdown=0
  while kill -0 "$app_pid" 2>/dev/null && (( shutdown < 8 )); do
    sleep 1
    (( shutdown += 1 ))
  done
  if kill -0 "$app_pid" 2>/dev/null; then
    print -u2 'fixture/no-network app did not terminate after TERM'
    return 1
  fi
  app_pid=""
}

mkdir -p "$pending/compact-validation" "$scratch/stage" "$mount" "$inspection_root"
build_inputs="$scratch/build-inputs-v5.json"
{
  print '{"schema_version":"latticelens-build-input-v5","files":['
  typeset -i first=1
  typeset -a build_input_files
  build_input_files=("${(@f)$( { find Sources Tests Scripts Assets Assets.xcassets LatticeLens.xcodeproj -type f -print 2>/dev/null; print -l Package.swift README.md CHANGELOG.md AppIcon-master.svg AppIcon-contact-sheet.png; } | LC_ALL=C sort -u)}")
  for input_file in "${build_input_files[@]}"; do
    [[ -f "$input_file" ]] || continue
    (( first )) || print ','
    first=0
    file_sha256="$(shasum -a 256 "$input_file" | awk '{print $1}')"
    jq -cn --arg input_path "$input_file" --arg sha256 "$file_sha256" '{path:$input_path,sha256:$sha256}'
  done
  print ']}'
} > "$build_inputs"
if ! jq -e '
  .schema_version == "latticelens-build-input-v5" and
  (.files | type == "array" and length > 0) and
  (.files | all(.[]; (.path | type == "string" and length > 0 and (startswith("/") | not) and (contains("..") | not)) and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))) and
  any(.files[]; .path == "Package.swift") and
  any(.files[]; .path == "README.md") and
  any(.files[]; .path == "CHANGELOG.md") and
  any(.files[]; .path | startswith("Sources/")) and
  any(.files[]; .path | startswith("Tests/")) and
  any(.files[]; .path | startswith("Scripts/")) and
  any(.files[]; .path | startswith("Assets.xcassets/")) and
  any(.files[]; .path | startswith("LatticeLens.xcodeproj/"))
' "$build_inputs" >/dev/null; then
  print -u2 'build_inputs: FAIL (manifest is empty, malformed, or does not cover every required v5 input class)'
  exit 65
fi
build_input_tree_sha256="$(shasum -a 256 "$build_inputs" | awk '{print $1}')"
[[ "$build_input_tree_sha256" == "$expected_build_input_tree_sha256" ]] || {
  print -u2 'refusing package: source/build inputs drifted since the prepackage validation run'
  exit 65
}
PATH="$packager_exec_path"
export PATH

xcodebuild -project LatticeLens.xcodeproj -scheme LatticeLens -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$scratch/DerivedData" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  SWIFT_STRICT_CONCURRENCY=complete build -quiet

app="$scratch/DerivedData/Build/Products/Release/LatticeLens.app"
binary="$app/Contents/MacOS/LatticeLens"
dsym="$scratch/DerivedData/Build/Products/Release/LatticeLens.app.dSYM"
verify_app "$app" '1.0.0' '100' allow_unsigned
[[ -d "$dsym" && -f "$dsym/Contents/Resources/DWARF/LatticeLens" ]] || {
  print -u2 'Release dSYM is missing'
  exit 1
}
app_uuids="$(dwarfdump --uuid "$binary" | awk '{print $2 " " $3}' | sort)"
dsym_uuids="$(dwarfdump --uuid "$dsym/Contents/Resources/DWARF/LatticeLens" | awk '{print $2 " " $3}' | sort)"
[[ -n "$app_uuids" && "$app_uuids" == "$dsym_uuids" ]] || {
  print -u2 'dSYM UUIDs do not match the release executable'
  exit 1
}

codesign --force --sign - --timestamp=none "$app"
verify_app "$app" '1.0.0' '100'

cp -R "$app" "$scratch/stage/LatticeLens.app"
ln -s /Applications "$scratch/stage/Applications"
dmg="$pending/LatticeLens-1.0.0-local.dmg"
hdiutil create -volname 'LatticeLens 1.0' -srcfolder "$scratch/stage" -ov -format UDZO "$dmg"
hdiutil verify "$dmg"

hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null
mounted=true
mounted_app="$mount/LatticeLens.app"
verify_app "$mounted_app" '1.0.0' '100'
ditto "$mounted_app" "$inspection_root/LatticeLens.app"
verify_app "$inspection_root/LatticeLens.app" '1.0.0' '100'
launch_fixture_smoke "$inspection_root/LatticeLens.app" "$scratch/fixture-smoke.log"
hdiutil detach "$mount" >/dev/null
mounted=false

dsym_zip="$pending/LatticeLens-1.0.0.dSYM.zip"
ditto -c -k --sequesterRsrc --keepParent "$dsym" "$dsym_zip"
dmg_sha256="$(shasum -a 256 "$dmg" | awk '{print $1}')"
dsym_sha256="$(shasum -a 256 "$dsym_zip" | awk '{print $1}')"
binary_sha256="$(shasum -a 256 "$binary" | awk '{print $1}')"
validation_sha256="$(shasum -a 256 "$validation" | awk '{print $1}')"
benchmark_evidence_sha256="$(shasum -a 256 "$benchmark_evidence" | awk '{print $1}')"
spctl_status='rejected_or_unavailable'
spctl -a -vv "$app" >"$pending/spctl-v1.0.0-local.txt" 2>&1 && spctl_status='accepted' || true

for evidence in "$validation" "$benchmark_evidence" VALIDATION_V5.md CHANGELOG.md; do
  [[ -f "$evidence" ]] && cp "$evidence" "$pending/compact-validation/"
done
cp "$build_inputs" "$pending/build-inputs-v5.json"
jq -n \
  --arg run_id "$run_id" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg build_input_tree_sha256 "$build_input_tree_sha256" \
  --arg validation_file "${validation#$root/}" \
  --arg validation_sha256 "$validation_sha256" \
  --arg benchmark_evidence_file "${benchmark_evidence#$root/}" \
  --arg benchmark_evidence_sha256 "$benchmark_evidence_sha256" \
  --arg binary_sha256 "$binary_sha256" \
  --arg dmg_sha256 "$dmg_sha256" \
  --arg dsym_sha256 "$dsym_sha256" \
  --arg architectures "$(lipo -archs "$binary")" \
  --arg spctl_status "$spctl_status" \
  --arg app_uuids "$app_uuids" \
  '{schema_version:"latticelens-package-manifest-v1.0",run_id:$run_id,generated_at_utc:$generated_at,artifact_class:"same_mac_local_ad_hoc",product_version:"1.0.0",build_number:100,minimum_macos:"14.0",bundle_id:"org.latticelens.app",signature_class:"ad_hoc_local",developer_id:false,notarized:false,dmg_smoke:"passed",spctl_status:$spctl_status,build_input_tree_sha256:$build_input_tree_sha256,prepackage_validation:{source_project_path:$validation_file,copied_file:("compact-validation/" + ($validation_file | split("/") | last)),sha256:$validation_sha256},benchmark_evidence:{source_project_path:$benchmark_evidence_file,copied_file:("compact-validation/" + ($benchmark_evidence_file | split("/") | last)),sha256:$benchmark_evidence_sha256},app:{bundle:"LatticeLens.app",architectures:$architectures,executable_sha256:$binary_sha256,icon_resource:"Contents/Resources/AppIcon.icns",dsym_uuids:$app_uuids},artifacts:{dmg:{file:"LatticeLens-1.0.0-local.dmg",sha256:$dmg_sha256},dsym:{file:"LatticeLens-1.0.0.dSYM.zip",sha256:$dsym_sha256}},install_boundary:"DMG smoke used only a project-local inspection copy with fixture/no-network launch; it did not write /Applications or a user library."}' \
  > "$pending/manifest-v1.0.json"

cat > "$pending/INSTALL_AND_ROLLBACK.md" <<'EOF'
# LatticeLens 1.0.0 — same-Mac local artifact

This DMG is ad-hoc signed for local inspection.  It is not Developer ID signed,
not notarized, and it must not be presented as a public macOS release.

## Install without overwriting an existing app

1. Verify `manifest-v1.0.json` and `SHA256SUMS.txt` before mounting the DMG.
2. If `/Applications/LatticeLens.app` already exists, choose one action before
   dragging the new app: retain and rename the old app, cancel, or replace it
   only after you have verified a backup.  Never silently overwrite it.
3. Start the installed app with network disabled for the local acceptance flow:
   browse cached authors, search, note, PDF, Compare, Notebook and Bundle;
   quit and relaunch to confirm durable state.

## Data rollback and uninstall

- If no V8 migration occurred, quit 1.0, remove only the new app and relaunch
  the retained app.  Do not delete Application Support, PDFs, Keychain or a
  library as part of an app rollback.
- If a V7→V8 migration occurred, verify the pre-migration backup manifest and
  hashes first. Restore it only to a new explicit target, verify record/link
  counts, then choose the active library. Do not point an old app at a V8 store.
- Default uninstall removes only `/Applications/LatticeLens.app`; it retains
  libraries, PDFs and Keychain. A full data purge is a separate human action
  after a verified Research Bundle export.
EOF

(
  cd "$pending"
  shasum -a 256 LatticeLens-1.0.0-local.dmg LatticeLens-1.0.0.dSYM.zip manifest-v1.0.json > SHA256SUMS.txt
)

mkdir "$out"
mv "$pending"/* "$out/"
rmdir "$pending"
print "Created $out"
