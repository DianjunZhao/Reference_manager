#!/bin/zsh
# Build a reproducible, local-only v2 archive and an evidence manifest.
#
# This intentionally does not make a Developer ID, notarization, Gatekeeper,
# cross-machine, XCUIApplication, or VoiceOver claim.  Its output is a
# pre-candidate artifact for local inspection only; the manifest records the
# remaining Gate I blockers explicitly.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$project_root/Release-v2}"

case "$output_dir" in
  "$project_root"/*) ;;
  *)
    print -u2 "Output directory must stay below the project root: $project_root"
    exit 2
    ;;
esac

if [[ -e "$output_dir" ]]; then
  print -u2 "Refusing to overwrite existing output: $output_dir"
  exit 2
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
scratch="$project_root/.codex-task-tmp-v2-archive-$run_id"
archive="$output_dir/LatticeLens-v2-unsigned.xcarchive"
app="$archive/Products/Applications/LatticeLens.app"
payload="$output_dir/LatticeLens-v2-unsigned-local.zip"
manifest="$output_dir/manifest-v2.json"
instructions="$output_dir/INSTALL_AND_ROLLBACK.md"

cleanup() {
  [[ -d "$scratch" ]] || return 0
  find "$scratch" -depth -type f -exec /bin/unlink {} ';'
  find "$scratch" -depth -type l -exec /bin/unlink {} ';'
  find "$scratch" -depth -type d -exec /bin/rmdir {} '+' 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mkdir -p "$output_dir" "$scratch"
cd "$project_root"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project LatticeLens.xcodeproj \
  -scheme LatticeLens \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$scratch/derived-data" \
  -archivePath "$archive" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  SWIFT_STRICT_CONCURRENCY=complete \
  archive -quiet

[[ -d "$app" ]] || { print -u2 "Archive does not contain LatticeLens.app"; exit 1; }
info_plist="$app/Contents/Info.plist"
[[ -f "$info_plist" ]] || { print -u2 "Archive app is missing Info.plist"; exit 1; }
/usr/bin/plutil -lint "$info_plist" >/dev/null

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist" 2>/dev/null || print ""
}

bundle_id="$(plist_value CFBundleIdentifier)"
bundle_name="$(plist_value CFBundleName)"
bundle_version="$(plist_value CFBundleVersion)"
executable_name="$(plist_value CFBundleExecutable)"
[[ "$bundle_id" == "org.latticelens.app" ]] || { print -u2 "Unexpected bundle identifier: $bundle_id"; exit 1; }
[[ -n "$executable_name" && -f "$app/Contents/MacOS/$executable_name" ]] || { print -u2 "Archive app executable is missing"; exit 1; }

architectures="$(/usr/bin/lipo -archs "$app/Contents/MacOS/$executable_name")"
if /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
  signature_state="verified_non_developer_id"
else
  signature_state="unsigned_or_unverified"
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$payload"
payload_sha256="$(/usr/bin/shasum -a 256 "$payload" | /usr/bin/awk '{print $1}')"
executable_sha256="$(/usr/bin/shasum -a 256 "$app/Contents/MacOS/$executable_name" | /usr/bin/awk '{print $1}')"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$manifest" <<EOF
{
  "schema_version": "latticelens-package-manifest-v2",
  "generated_at_utc": "$generated_at",
  "artifact_class": "unsigned_local_pre_candidate",
  "source_root": ".",
  "build": {
    "scheme": "LatticeLens",
    "configuration": "Release",
    "destination": "generic/platform=macOS",
    "code_signing_allowed": false,
    "swift_warnings_as_errors": true,
    "swift_strict_concurrency": "complete"
  },
  "app": {
    "archive": "LatticeLens-v2-unsigned.xcarchive",
    "bundle_id": "$bundle_id",
    "bundle_name": "$bundle_name",
    "bundle_version": "$bundle_version",
    "executable": "$executable_name",
    "architectures": "$architectures",
    "executable_sha256": "$executable_sha256",
    "signature_state": "$signature_state"
  },
  "payload": {
    "file": "LatticeLens-v2-unsigned-local.zip",
    "sha256": "$payload_sha256"
  },
  "release_status": {
    "local_candidate": "blocked",
    "public_release": "not_run",
    "blockers": [
      "No VoiceOver manual pass",
      "No Developer ID signature",
      "No notarization or Gatekeeper/cross-machine evidence"
    ]
  },
  "verification": {
    "archive_contains_app": true,
    "info_plist_valid": true,
    "bundle_identifier_verified": true,
    "payload_sha256_verified_at_creation": true
  }
}
EOF

cat > "$instructions" <<'EOF'
# LatticeLens v2 unsigned local archive

This directory is a **local pre-candidate artifact**, not an installer and not
a public release. Its `manifest-v2.json` contains the exact payload SHA-256,
bundle metadata, build configuration, and the unresolved release blockers.

## Inspect without weakening macOS security

Verify the payload in this directory before inspecting it:

```zsh
cd $PROJECT_ROOT/Release-v2
shasum -a 256 LatticeLens-v2-unsigned-local.zip
```

The output must equal `payload.sha256` in `manifest-v2.json`. Unzip only to a
user-chosen temporary location. Do **not** bypass Gatekeeper or alter macOS
security settings if the unsigned build is blocked. The supported developer
workflow remains opening `LatticeLens.xcodeproj` in Xcode and running a local
Debug build with fixture dependencies when appropriate.

## Rollback and data boundary

This archive does not install, modify, or delete any user library by itself.
For a local inspection, quit the inspected app and remove only the extracted
copy you chose. Do not remove Application Support, caches, Keychain entries,
or an existing installed LatticeLens copy as part of rollback.

## Acceptance boundary

This artifact demonstrates only archive construction, bundle metadata, and
payload hashing. The separately recorded fixture `XCUIApplication` suite does
not replace a VoiceOver/manual pass. Gate I stays **Blocked** until that pass,
Developer ID signing, notarization, Gatekeeper, and cross-machine installation
evidence exist.
EOF

print "Created local v2 pre-candidate archive: $output_dir"
print "Manifest: $manifest"
print "Payload SHA-256: $payload_sha256"
