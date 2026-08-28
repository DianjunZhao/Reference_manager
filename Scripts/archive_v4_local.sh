#!/bin/zsh
# Build an independent same-Mac v4 local artifact.  This script never touches
# Release-v2/Release-v3 and refuses to overwrite an existing output directory.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$project_root/Release-v4-local}"
case "$output_dir" in
  "$project_root"/*) ;;
  *) print -u2 "output must stay below project root"; exit 2 ;;
esac
[[ -e "$output_dir" ]] && { print -u2 "Refusing to overwrite existing output: $output_dir"; exit 2; }

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
scratch="$project_root/.codex-task-tmp-v4-archive-$run_id"
archive="$output_dir/LatticeLens-v4-local.xcarchive"
app="$archive/Products/Applications/LatticeLens.app"
payload="$output_dir/LatticeLens-v4-local.zip"
manifest="$output_dir/manifest-v4.json"

cleanup() {
  [[ -d "$scratch" ]] || return 0
  find "$scratch" -depth -type f -exec /bin/unlink {} ';'
  find "$scratch" -depth -type l -exec /bin/unlink {} ';'
  find "$scratch" -depth -type d -exec /bin/rmdir {} '+' 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' INT TERM

mkdir -p "$output_dir" "$scratch"
cd "$project_root"
xcodebuild -project LatticeLens.xcodeproj -scheme LatticeLens -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$scratch/derived" \
  -archivePath "$archive" CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  SWIFT_STRICT_CONCURRENCY=complete archive -quiet

[[ -d "$app" ]] || { print -u2 "archive missing app"; exit 1; }
info_plist="$app/Contents/Info.plist"
/usr/bin/plutil -lint "$info_plist" >/dev/null
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist" 2>/dev/null || print ""; }
bundle_id="$(plist_value CFBundleIdentifier)"
executable_name="$(plist_value CFBundleExecutable)"
architectures="$(/usr/bin/lipo -archs "$app/Contents/MacOS/$executable_name")"
executable_sha256="$(/usr/bin/shasum -a 256 "$app/Contents/MacOS/$executable_name" | /usr/bin/awk '{print $1}')"
signature_state="unsigned_or_unverified"
/usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 && signature_state="adhoc_or_locally_verified" || true
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$payload"
payload_sha256="$(/usr/bin/shasum -a 256 "$payload" | /usr/bin/awk '{print $1}')"
source_hash="$(find Sources Tests Scripts -type f ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
validation_artifact_hash="$(jq -r '.artifact_hash // empty' validation-v4.json 2>/dev/null || true)"
validation_matches_current_source=false
[[ -n "$validation_artifact_hash" && "$validation_artifact_hash" == "$source_hash" ]] && validation_matches_current_source=true
# The archive must not retain a historical XCTest-bootstrap blocker after a
# current, source-matched verifier has produced a complete UI aggregate.  This
# condition remains deliberately narrow: it establishes only the scripted
# local evidence; manual acceptance and a disposable-library drill stay
# explicit blockers.
current_verifier_status="missing_or_not_current"
local_candidate_status="blocked_until_current_ui_aggregate_and_manual_local_drill"
release_blockers='["Current mandatory verifier is missing, nonzero, or does not match this source hash", "Manual local browse/search/note/PDF/Compare acceptance and disposable user-library rollback drill not run"]'
if [[ "$validation_matches_current_source" == true ]] && /usr/bin/jq -e '
  (.failures == 0) and
  (.ui_runtime.feature_complete_gate == true) and
  (.ui_runtime.readable_result == true) and
  (.ui_runtime.total >= 18) and
  (.ui_runtime.passed == .ui_runtime.total) and
  (.ui_runtime.failed == 0)
' validation-v4.json >/dev/null 2>&1; then
  current_verifier_status="passed_current_18_case_fixture_aggregate"
  local_candidate_status="pending_manual_local_drill"
  release_blockers='["Manual local browse/search/note/PDF/Compare acceptance not run", "Disposable user-library migration/backup/rollback drill not run"]'
fi
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Preserve only auditable local ledgers next to this independent artifact.
for evidence in validation-v4.json benchmark-v4.json validation-v4-ui-summary.json \
  validation-v4-ui-independent-summary.json v4_completion_checklist.json VALIDATION_V4.md; do
  [[ -f "$project_root/$evidence" ]] && cp "$project_root/$evidence" "$output_dir/$evidence"
done

cat > "$manifest" <<EOF
{
  "schema_version": "latticelens-package-manifest-v4",
  "generated_at_utc": "$generated_at",
  "artifact_class": "same_mac_unsigned_local_artifact",
  "build": {
    "scheme": "LatticeLens",
    "configuration": "Release",
    "destination": "generic/platform=macOS",
    "code_signing_allowed": false,
    "swift_warnings_as_errors": true,
    "swift_strict_concurrency": "complete"
  },
  "app": {
    "archive": "LatticeLens-v4-local.xcarchive",
    "bundle_id": "$bundle_id",
    "executable": "$executable_name",
    "architectures": "$architectures",
    "executable_sha256": "$executable_sha256",
    "signature_state": "$signature_state"
  },
  "payload": {"file": "LatticeLens-v4-local.zip", "sha256": "$payload_sha256"},
  "source": {"artifact_hash": "$source_hash", "validation_artifact_hash": "$validation_artifact_hash", "validation_matches_current_source": $validation_matches_current_source, "validation": "validation-v4.json", "benchmark": "benchmark-v4.json"},
  "release_status": {
    "same_mac_install": "fixture_smoke_pending",
    "current_verifier": "$current_verifier_status",
    "local_candidate": "$local_candidate_status",
    "public_release": "not_run",
    "blockers": $release_blockers
  }
}
EOF

cat > "$output_dir/INSTALL_AND_ROLLBACK.md" <<'EOF'
# LatticeLens v4 same-Mac local artifact

This directory is an independent, unsigned/local-development artifact. Verify
`manifest-v4.json` and the payload SHA-256 before inspecting it. Extract the
zip into a user-selected temporary directory and launch the app there; this
does not install over an existing app, open a user library, contact INSPIRE,
or send a provider request. The app remains fixture/offline only unless the
user explicitly configures a provider and accepts its disclosure.

Rollback is deliberately non-destructive: quit the inspection copy, remove
only that extracted copy, and relaunch the previously retained app. Do not
delete Application Support, Keychain entries, PDFs, old releases, or the
active library. Research Bundle restore also requires a new target and never
overwrites an active store.

Artifact class: `same_mac_unsigned_local_artifact`. Developer ID signing,
notarization, Gatekeeper, VoiceOver/manual acceptance, and cross-machine
installation are not established by this package.
EOF

# Gate R's scripted portion is part of archive creation, not a claim inferred
# from a successful compile.  The smoke verifies the payload hash, launches
# the extracted app with the in-memory fixture graph for at least three
# seconds, terminates only that process and removes only its inspection copy.
zsh "$project_root/Scripts/smoke_v4_local_archive.sh" "$output_dir"

# Promote this one field only after the smoke command above returned success.
# A failed smoke leaves its independent archive visibly pending rather than
# claiming that its app was launched successfully.
manifest_stage="$scratch/manifest-after-smoke.json"
jq '.release_status.same_mac_install = "fixture_smoke_passed"' "$manifest" > "$manifest_stage"
mv "$manifest_stage" "$manifest"

print "Created $output_dir (payload SHA-256: $payload_sha256)"
