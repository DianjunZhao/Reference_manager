#!/bin/zsh
# Fail-closed final package seal for the 1.0.1 (101) local candidate.
#
# This script intentionally does not rerun the historical 1.0.0 test matrix.
# It binds the two byte-identical release directories, the installed 1.0.1
# executable, and an explicit current-manifest manual-attestation receipt.
set -u -o pipefail

root="${0:A:h:h}"
project_root="${root:h}"
local_release="$project_root/Release-1.0.0-local"
github_release="$root/release-assets/Release-1.0.1-local"
manifest_name="manifest-v1.0.1.json"
dmg_name="LatticeLens-1.0.1-local.dmg"
manual_receipt=""
installed_app="/Applications/LatticeLens.app"

die() {
  print -u2 -- "seal-1.0.1: FAIL ($1)"
  exit 1
}

usage() {
  print -u2 "usage: zsh Scripts/verify_v1_0_1_seal.sh --manual-receipt evidence/ManualAcceptanceReceipt-v1.0.1-*.json [--installed-app /Applications/LatticeLens.app]"
  exit 64
}

while (( $# > 0 )); do
  case "$1" in
    --manual-receipt)
      (( $# >= 2 )) || usage
      manual_receipt="$2"
      shift 2
      ;;
    --installed-app)
      (( $# >= 2 )) || usage
      installed_app="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$manual_receipt" ]] || {
  print -u2 'seal-1.0.1: BLOCKED (a current 1.0.1 manual receipt is required)'
  exit 1
}

manual_receipt="${manual_receipt:A}"
installed_app="${installed_app:A}"
[[ "$manual_receipt" == "$root/evidence/"* && -f "$manual_receipt" && ! -L "$manual_receipt" ]] || \
  die 'manual receipt must be a regular file under github/evidence'

for release_dir in "$local_release" "$github_release"; do
  [[ -d "$release_dir" && ! -L "$release_dir" ]] || die "release directory missing: ${release_dir:t}"
  [[ -f "$release_dir/$manifest_name" && ! -L "$release_dir/$manifest_name" ]] || die "manifest missing: ${release_dir:t}"
  [[ -f "$release_dir/$dmg_name" && ! -L "$release_dir/$dmg_name" ]] || die "DMG missing: ${release_dir:t}"
  [[ -f "$release_dir/SHA256SUMS.txt" && ! -L "$release_dir/SHA256SUMS.txt" ]] || die "checksum list missing: ${release_dir:t}"
  (cd "$release_dir" && shasum -a 256 -c SHA256SUMS.txt) >/dev/null || die "checksum mismatch: ${release_dir:t}"
done

local_manifest_hash="$(shasum -a 256 "$local_release/$manifest_name" | awk '{print $1}')"
github_manifest_hash="$(shasum -a 256 "$github_release/$manifest_name" | awk '{print $1}')"
[[ "$local_manifest_hash" == "$github_manifest_hash" ]] || die 'local and GitHub manifests differ'
cmp -s "$local_release/$manifest_name" "$github_release/$manifest_name" || die 'local and GitHub manifest bytes differ'
cmp -s "$local_release/$dmg_name" "$github_release/$dmg_name" || die 'local and GitHub DMG bytes differ'

jq -e '
  .schema_version == "latticelens-local-candidate-v1.0.1" and
  .product_version == "1.0.1" and .build_number == 101 and
  .artifact_class == "same_mac_local_ad_hoc_candidate" and
  .signature_class == "ad_hoc_local" and .developer_id == false and .notarized == false and
  (.app.executable_sha256 | test("^[0-9a-f]{64}$")) and
  .artifacts.dmg.file == "LatticeLens-1.0.1-local.dmg" and
  (.artifacts.dmg.sha256 | test("^[0-9a-f]{64}$"))
' "$github_release/$manifest_name" >/dev/null || die '1.0.1 manifest is malformed or has the wrong release identity'

manifest_dmg_hash="$(jq -r '.artifacts.dmg.sha256' "$github_release/$manifest_name")"
actual_dmg_hash="$(shasum -a 256 "$github_release/$dmg_name" | awk '{print $1}')"
[[ "$manifest_dmg_hash" == "$actual_dmg_hash" ]] || die 'manifest DMG hash does not match the actual DMG'
/usr/bin/hdiutil verify "$github_release/$dmg_name" >/dev/null || die 'DMG image verification failed'

jq -e --arg manifest_hash "$github_manifest_hash" '
  .schema_version == "latticelens-manual-acceptance-v1.0.1" and
  .package_manifest_sha256 == $manifest_hash and
  .product_version == "1.0.1" and .build_number == 101 and
  .mandatory.voiceover == true and .mandatory.lqcd_rubric == true and
  .mandatory.applications_install == true and .mandatory.disposable_library_drill == true and
  (.applications_installation_choice == "preserved_and_renamed_old_app" or
   .applications_installation_choice == "replaced_after_verified_backup" or
   .applications_installation_choice == "no_old_app") and
  (.attestation | type == "string" and length > 0)
' "$manual_receipt" >/dev/null || die 'manual receipt is absent, stale, incomplete, or not bound to 1.0.1'

[[ -d "$installed_app" && ! -L "$installed_app" && -x "$installed_app/Contents/MacOS/LatticeLens" ]] || \
  die 'installed app bundle is missing or invalid'
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$installed_app/Contents/Info.plist")" == "1.0.1" ]] || \
  die 'installed app version is not 1.0.1'
[[ "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$installed_app/Contents/Info.plist")" == "101" ]] || \
  die 'installed app build is not 101'
/usr/bin/codesign --verify --deep --strict --verbose=2 "$installed_app" >/dev/null 2>&1 || die 'installed app signature verification failed'

expected_executable_hash="$(jq -r '.app.executable_sha256' "$github_release/$manifest_name")"
actual_executable_hash="$(shasum -a 256 "$installed_app/Contents/MacOS/LatticeLens" | awk '{print $1}')"
[[ "$expected_executable_hash" == "$actual_executable_hash" ]] || die 'installed app executable hash does not match the 1.0.1 manifest'

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
seal_receipt="$root/evidence/SealReceipt-v1.0.1-$run_id.json"
[[ ! -e "$seal_receipt" ]] || die 'refusing to overwrite an existing seal receipt'
manual_receipt_hash="$(shasum -a 256 "$manual_receipt" | awk '{print $1}')"

umask 077
jq -n \
  --arg run_id "$run_id" \
  --arg manifest_sha256 "$github_manifest_hash" \
  --arg dmg_sha256 "$actual_dmg_hash" \
  --arg manual_path "evidence/${manual_receipt:t}" \
  --arg manual_sha256 "$manual_receipt_hash" \
  --arg executable_sha256 "$actual_executable_hash" \
  --arg install_choice "$(jq -r '.applications_installation_choice' "$manual_receipt")" \
  '{schema_version:"latticelens-seal-v1.0.1",result:"PASS",run_id:$run_id,product_version:"1.0.1",build_number:101,artifact_class:"same_mac_local_ad_hoc_candidate",package_manifest:{path:"release-assets/Release-1.0.1-local/manifest-v1.0.1.json",sha256:$manifest_sha256},release_assets:{dmg_sha256:$dmg_sha256,local_and_github_copies_byte_identical:true,hdiutil_verify:true},installed_application:{bundle:"/Applications/LatticeLens.app",version:"1.0.1",build_number:101,executable_sha256:$executable_sha256,codesign_verify:true},manual_acceptance:{path:$manual_path,sha256:$manual_sha256,applications_installation_choice:$install_choice},mandatory:{manifest_and_checksums:true,dmg_image:true,installed_binary:true,manual_voiceover:true,manual_lqcd_rubric:true,manual_applications_install:true,manual_disposable_library_drill:true},out_of_scope:{developer_id:true,notarization:true,cross_machine:true,live_llm:true},failures:0}' \
  >"$seal_receipt" || die 'could not write seal receipt'

print "seal-1.0.1: PASS ($seal_receipt)"
