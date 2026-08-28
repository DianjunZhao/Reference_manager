#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$project_root/Release-v3}"
case "$output_dir" in "$project_root"/*) ;; *) print -u2 "output must stay below project root"; exit 2 ;; esac
[[ -e "$output_dir" ]] && { print -u2 "Refusing to overwrite existing output: $output_dir"; exit 2; }
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
scratch="$project_root/.codex-task-tmp-v3-archive-$run_id"
archive="$output_dir/LatticeLens-v3-unsigned.xcarchive"
app="$archive/Products/Applications/LatticeLens.app"
payload="$output_dir/LatticeLens-v3-unsigned-local.zip"
manifest="$output_dir/manifest-v3.json"
cleanup() { [[ -d "$scratch" ]] || return 0; find "$scratch" -depth -type f -exec /bin/unlink {} ';'; find "$scratch" -depth -type l -exec /bin/unlink {} ';'; find "$scratch" -depth -type d -exec /bin/rmdir {} '+' 2>/dev/null || true; }
trap cleanup EXIT INT TERM
mkdir -p "$output_dir" "$scratch"
cd "$project_root"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project LatticeLens.xcodeproj -scheme LatticeLens -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$scratch/derived-data" -archivePath "$archive" CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_STRICT_CONCURRENCY=complete archive -quiet
[[ -d "$app" ]] || { print -u2 "archive missing app"; exit 1; }
info_plist="$app/Contents/Info.plist"; /usr/bin/plutil -lint "$info_plist" >/dev/null
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist" 2>/dev/null || print ""; }
bundle_id="$(plist_value CFBundleIdentifier)"; executable_name="$(plist_value CFBundleExecutable)"; architectures="$(/usr/bin/lipo -archs "$app/Contents/MacOS/$executable_name")"
signature_state="unsigned_or_unverified"; /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 && signature_state="verified_non_developer_id" || true
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$payload"
payload_sha256="$(/usr/bin/shasum -a 256 "$payload" | /usr/bin/awk '{print $1}')"; executable_sha256="$(/usr/bin/shasum -a 256 "$app/Contents/MacOS/$executable_name" | /usr/bin/awk '{print $1}')"; generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$manifest" <<EOF
{
  "schema_version": "latticelens-package-manifest-v3",
  "generated_at_utc": "$generated_at",
  "artifact_class": "unsigned_local_pre_candidate",
  "build": {"scheme": "LatticeLens", "configuration": "Release", "destination": "generic/platform=macOS", "code_signing_allowed": false, "swift_warnings_as_errors": true, "swift_strict_concurrency": "complete"},
  "app": {"archive": "LatticeLens-v3-unsigned.xcarchive", "bundle_id": "$bundle_id", "executable": "$executable_name", "architectures": "$architectures", "executable_sha256": "$executable_sha256", "signature_state": "$signature_state"},
  "payload": {"file": "LatticeLens-v3-unsigned-local.zip", "sha256": "$payload_sha256"},
  "evidence": {"benchmark": "../benchmark-v3.json", "validation": "../validation-v3.json", "source_scope": "local-only"},
  "release_status": {"local_candidate": "blocked", "public_release": "not_run", "blockers": ["VoiceOver/manual pass not run", "Developer ID signing not available", "notarization/Gatekeeper/cross-machine evidence not run"]}
}
EOF
cat > "$output_dir/INSTALL_AND_ROLLBACK.md" <<'EOF'
# LatticeLens v3 unsigned local artifact

This is an unsigned local pre-candidate. Verify `manifest-v3.json` and the
payload SHA-256 before extracting to a user-selected temporary directory.
It does not install, modify, upload, or delete a user library. Remove only the
extracted inspection copy when finished; do not remove Application Support,
Keychain entries, caches, or an existing app. Developer ID, notarization,
Gatekeeper, VoiceOver/manual and cross-machine release gates remain blocked.
EOF
print "Created $output_dir (payload SHA-256: $payload_sha256)"
