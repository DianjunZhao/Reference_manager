#!/bin/zsh
# Single fail-closed local verification entry for the 1.0 release candidate.
set -u -o pipefail
root="${0:A:h:h}"
cd "$root"
mode="${1:-}"
[[ $# -eq 1 && ( "$mode" == "--local-only" || "$mode" == "--seal-only" ) ]] || {
  print -u2 'usage: zsh Scripts/verify_v5.sh --local-only | --seal-only'
  exit 64
}
# zsh exposes `path` as the array view of PATH.  XCTest/Xcode subprocesses
# must never inherit a transient shell array that happens to be named `path`;
# keep the verified launch path from verifier entry and inject it explicitly
# into every bounded child runner.
verifier_exec_path="${PATH:-}"
[[ -n "$verifier_exec_path" && -x /usr/bin/env && -x /usr/bin/xcrun ]] || {
  print -u2 'verifier environment has no usable command path'
  exit 66
}
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
scratch="$root/.build/verify-v5-$run_id"
mkdir -p "$scratch"
summary="$root/validation-v5-$run_id.json"
[[ ! -e "$summary" ]] || { print -u2 "refusing to overwrite $summary"; exit 65; }
typeset -i failures=0
restore_verifier_exec_path() {
  PATH="$verifier_exec_path"
  export PATH
}
run_gate() {
  local name="$1"
  shift
  restore_verifier_exec_path
  if "$@" >"$scratch/$name.log" 2>&1; then
    restore_verifier_exec_path
    print -- "$name: PASS"
    return 0
  fi
  restore_verifier_exec_path
  print -u2 -- "$name: FAIL (see $scratch/$name.log)"
  failures+=1
  return 1
}

# `swift test` exits zero for an explicit opt-in XCTSkip.  That is correct for
# the benchmark-free developer loop, but the final verifier must distinguish
# the one remaining user-authorized migration drill skip from any accidental
# skip introduced by a regression.  The benchmark is enabled below, so this
# function deliberately permits only the authorized external-data test.
swiftpm_has_only_expected_opt_in_skip() {
  local skips
  # XCTest's current formatter writes `Test Case … skipped`, whereas an older
  # verifier looked for the obsolete `Test skipped -` text and therefore
  # turned an otherwise successful benchmark run into a false failure.
  # Restrict this to individual XCTest case records so aggregate summaries
  # such as `1 test skipped` cannot be counted as an authorized skip.
  skips="$(rg -n 'Test Case .* skipped' "$scratch/swiftpm.log" || true)"
  [[ -n "$skips" ]] || return 1
  [[ "$skips" == *'testAuthorizedDisposableV7MigrationDrill'* ]] || return 1
  [[ "$(print -r -- "$skips" | wc -l | tr -d ' ')" == '1' ]]
}

# Keep automatic feature gates grounded in the current suite's concrete
# XCTest evidence, rather than a source grep or a hard-coded optimistic flag.
# Every required name must appear on a passing XCTest case line in this run.
swiftpm_contract_tests_passed() {
  local test_name
  for test_name in "$@"; do
    rg -q -- "${test_name}.*passed" "$scratch/swiftpm.log" || return 1
  done
}

# Host XCTest runners can stop reporting progress while leaving descendants
# alive.  Each Xcode command therefore owns a private process group and has a
# real bound; a timeout is fail-closed and cannot fall back to old evidence.
run_bounded_xcode_command() {
  local timeout_seconds="$1"; shift
  restore_verifier_exec_path
  /usr/bin/perl -MPOSIX -MTime::HiRes -e '
    my $timeout = shift @ARGV;
    my $exec_path = shift @ARGV;
    $ENV{PATH} = $exec_path;
    my $child = fork();
    die "fork failed: $!\n" unless defined $child;
    if ($child == 0) {
      POSIX::setpgid(0, 0) or die "setpgid failed: $!\n";
      exec @ARGV;
      die "exec failed: $!\n";
    }
    POSIX::setpgid($child, $child);
    my $timed_out = 0;
    local $SIG{ALRM} = sub {
      $timed_out = 1;
      print STDERR "TIMEOUT after ${timeout}s; terminating task-owned Xcode process group ${child}\n";
      kill "TERM", -$child;
    };
    alarm $timeout;
    my $waited = waitpid($child, 0);
    alarm 0;
    if ($timed_out) {
      kill "KILL", -$child;
      Time::HiRes::sleep(0.2);
      waitpid($child, POSIX::WNOHANG());
      exit 124;
    }
    exit 127 if $waited == -1;
    exit 128 + ($? & 127) if $? & 127;
    exit $? >> 8;
  ' "$timeout_seconds" "$verifier_exec_path" "$@"
}

xcode_timeout_seconds="${LATTICELENS_V5_XCODE_TIMEOUT_SECONDS:-600}"
ui_timeout_seconds="${LATTICELENS_V5_UI_TIMEOUT_SECONDS:-900}"
xcresult_timeout_seconds="${LATTICELENS_V5_XCRESULT_TIMEOUT_SECONDS:-30}"
current_xcresult_is_readable() {
  # `path` is zsh's special array tied to `$PATH`; never use it as a local
  # name here or the subsequent jq invocation becomes undiscoverable.
  local result_bundle="$1" output="$2"
  [[ -d "$result_bundle" ]] || return 1
  run_bounded_xcode_command "$xcresult_timeout_seconds" /usr/bin/xcrun xcresulttool get test-results summary --path "$result_bundle" >"$output" 2>&1 || return 1
  # A syntactically readable bundle can still be an empty/unknown Xcode
  # aggregate (for example when the UI runner never materializes workers).
  # That is not a test pass and must not satisfy any mandatory Xcode gate.
  jq -e '(.result == "Passed") and ((.totalTestCount | numbers) > 0) and ((.failedTests | numbers) == 0)' "$output" >/dev/null
}

# A test plan may report a syntactically valid result while silently skipping
# every executable case.  The unit target deliberately has two named opt-in
# external-data skips; a current unit result must have exactly those two, not
# an arbitrary additional skipped test.  UI results have no such exception.
current_unit_xcresult_is_complete() {
  local result_bundle="$1" output="$2"
  current_xcresult_is_readable "$result_bundle" "$output" || return 1
  jq -e '(.skippedTests == 2) and ((.passedTests | numbers) > 0)' "$output" >/dev/null
}

current_ui_xcresult_is_complete() {
  local result_bundle="$1" output="$2" expected_test_count="$3"
  current_xcresult_is_readable "$result_bundle" "$output" || return 1
  jq -e --argjson expected_test_count "$expected_test_count" '
    (.skippedTests == 0) and
    (.totalTestCount == $expected_test_count) and
    (.passedTests == $expected_test_count)
  ' "$output" >/dev/null
}

xctestrun_for_scheme() {
  local derived_data="$1" scheme_name="$2" candidate
  restore_verifier_exec_path
  candidate="$(find "$derived_data/Build/Products" -maxdepth 1 -type f -name "${scheme_name}_*.xctestrun" -print -quit 2>/dev/null || true)"
  [[ -n "$candidate" && -f "$candidate" && ! -L "$candidate" ]] || return 1
  print -r -- "$candidate"
}

task_owned_xcode_pids() {
  /bin/ps -axo pid=,command= | /usr/bin/awk -v marker="$scratch/" '
    index($0, marker) && ($0 ~ /xcodebuild/ || $0 ~ /LatticeLens.*Tests-Runner/ || $0 ~ /LatticeLens\.app\/Contents\/MacOS\/LatticeLens/ ||
                           $0 ~ /swift-frontend/ || $0 ~ /swiftc/ || $0 ~ /clang/ || $0 ~ /actool/ || $0 ~ /ibtool/ || $0 ~ /\/(ld|codesign)$/) { print $1 }
  '
}

cleanup_task_owned_xcode_processes() {
  local listing
  local -a pids
  listing="$(task_owned_xcode_pids)"
  [[ -n "$listing" ]] || return 0
  pids=("${(@f)listing}")
  print -u2 "CLEANUP terminating task-owned Xcode-derived process(es): ${pids[*]}"
  /bin/kill -TERM "${pids[@]}" 2>/dev/null || true
  /bin/sleep 1
  listing="$(task_owned_xcode_pids)"
  [[ -n "$listing" ]] || return 0
  pids=("${(@f)listing}")
  print -u2 "CLEANUP force-terminating remaining task-owned Xcode-derived process(es): ${pids[*]}"
  /bin/kill -KILL "${pids[@]}" 2>/dev/null || true
}

run_xcode_gate() {
  local name="$1" timeout_seconds="$2"; shift 2
  run_gate "$name" run_bounded_xcode_command "$timeout_seconds" "$@"
  local gate_exit=$?
  cleanup_task_owned_xcode_processes
  return "$gate_exit"
}

verify_icon_version() {
  local app="$scratch/DerivedData/Build/Products/Release/LatticeLens.app"
  [[ -f "$app/Contents/Info.plist" && -s "$app/Contents/Resources/AppIcon.icns" ]] || return 1
  [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" == "1.0.0" ]] &&
    [[ "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")" == "100" ]]
}

# A full `--local-only` run intentionally captures all automated evidence
# before packaging, while the human worksheet can only be bound *after* the
# newly built DMG has been mounted and inspected.  Re-running every compiler,
# benchmark, unit, migration, and UI action solely to attach that receipt
# would add test repetitions without increasing the evidence for the same
# immutable source tree.  `--seal-only` is therefore a narrow, fail-closed
# finalizer: it accepts a current full automatic record, re-hashes this source
# tree, re-smokes the package, validates the approved cleanup receipt, and
# binds the four manual gates.  It never claims to execute new automated
# tests.
seal_only() {
  local automatic_validation manual_receipt release_dir package_manifest
  local automatic_validation_sha256 package_manifest_sha256 cleanup_receipt
  automatic_validation="${LATTICELENS_V5_AUTOMATIC_VALIDATION_JSON:-}"
  manual_receipt="${LATTICELENS_V5_MANUAL_ACCEPTANCE_JSON:-}"
  release_dir="$root/Release-1.0.0-local"
  package_manifest="$release_dir/manifest-v1.0.json"

  [[ -n "$automatic_validation" && -n "$manual_receipt" ]] || {
    print -u2 'seal: BLOCKED (set LATTICELENS_V5_AUTOMATIC_VALIDATION_JSON and LATTICELENS_V5_MANUAL_ACCEPTANCE_JSON)'
    return 1
  }
  automatic_validation="${automatic_validation:A}"
  manual_receipt="${manual_receipt:A}"
  [[ "$automatic_validation" == "$root"/* && -f "$automatic_validation" && ! -L "$automatic_validation" ]] || {
    print -u2 'seal: FAIL (automatic validation must be a project-local regular file)'
    return 1
  }
  [[ "$manual_receipt" == "$root"/* && -f "$manual_receipt" && ! -L "$manual_receipt" ]] || {
    print -u2 'seal: FAIL (manual receipt must be a project-local regular file)'
    return 1
  }
  [[ -d "$release_dir" && -f "$package_manifest" && ! -L "$package_manifest" ]] || {
    print -u2 'seal: FAIL (current Release-1.0.0-local package manifest is absent)'
    return 1
  }

  jq -e --arg tree_hash "$tree_hash" '
    .schema_version == "latticelens-verify-v5" and
    .local_only == true and .build_input_tree_sha256 == $tree_hash and
    (.mandatory.swiftpm == true) and
    (.mandatory.actual_swiftdata_benchmark == true) and
    (.mandatory.swiftpm_release == true) and
    (.mandatory.xcode_build_analyze == true) and
    (.mandatory.xcode_unit == true) and
    (.mandatory.ui_normal == true) and
    (.mandatory.ui_large_scroll_accessibility == true) and
    (.mandatory.typed_store == true) and
    (.mandatory.migration_backup_rollback == true) and
    (.mandatory.physics_validator == true) and
    (.mandatory.radar == true) and
    (.mandatory.compare == true) and
    (.mandatory.notebook == true) and
    (.mandatory.bundle == true) and
    (.mandatory.icon_version_resources == true) and
    (.mandatory.dmg_smoke == true) and (.mandatory.cleanup == true) and
    (.cleanup.status == "applied") and
    (.cleanup.applyReceipt.path | type == "string" and length > 0) and
    (.cleanup.applyReceipt.sha256 | test("^[0-9a-f]{64}$")) and
    (.artifacts.package_manifest.path == "Release-1.0.0-local/manifest-v1.0.json") and
    (.artifacts.package_manifest.sha256 | test("^[0-9a-f]{64}$"))
  ' "$automatic_validation" >/dev/null || {
    print -u2 'seal: FAIL (automatic validation is incomplete, failed, or belongs to different build inputs)'
    return 1
  }

  cleanup_receipt="$root/$(jq -r '.cleanup.applyReceipt.path' "$automatic_validation")"
  [[ -f "$cleanup_receipt" && ! -L "$cleanup_receipt" ]] &&
    [[ "$(shasum -a 256 "$cleanup_receipt" | awk '{print $1}')" == "$(jq -r '.cleanup.applyReceipt.sha256' "$automatic_validation")" ]] || {
    print -u2 'seal: FAIL (approved cleanup receipt is absent or hash-mismatched)'
    return 1
  }
  jq -e '
    .schema_version == "latticelens-cleanup-apply-receipt-v1.0" and .result == "applied" and
    (.deletedRelativePaths | type == "array") and (.alreadyAbsentRelativePaths | type == "array")
  ' "$cleanup_receipt" >/dev/null || {
    print -u2 'seal: FAIL (approved cleanup receipt is malformed)'
    return 1
  }

  package_manifest_sha256="$(shasum -a 256 "$package_manifest" | awk '{print $1}')"
  [[ "$package_manifest_sha256" == "$(jq -r '.artifacts.package_manifest.sha256' "$automatic_validation")" ]] || {
    print -u2 'seal: FAIL (package manifest no longer matches the automatic validation record)'
    return 1
  }
  jq -e --arg tree_hash "$tree_hash" '
    .schema_version == "latticelens-package-manifest-v1.0" and
    .artifact_class == "same_mac_local_ad_hoc" and .product_version == "1.0.0" and
    .build_number == 100 and .signature_class == "ad_hoc_local" and
    .developer_id == false and .notarized == false and .dmg_smoke == "passed" and
    .build_input_tree_sha256 == $tree_hash
  ' "$package_manifest" >/dev/null && zsh Scripts/smoke_v1_local_dmg.sh "$release_dir" >/dev/null || {
    print -u2 'seal: FAIL (current package manifest or independent DMG smoke check failed)'
    return 1
  }

  jq -e --arg package_sha256 "$package_manifest_sha256" '
    .schema_version == "latticelens-manual-acceptance-v5" and
    .package_manifest_sha256 == $package_sha256 and
    .mandatory.voiceover == true and .mandatory.lqcd_rubric == true and
    .mandatory.applications_install == true and .mandatory.disposable_library_drill == true and
    (.applications_installation_choice == "preserved_and_renamed_old_app" or
     .applications_installation_choice == "replaced_after_verified_backup" or
     .applications_installation_choice == "no_old_app")
  ' "$manual_receipt" >/dev/null || {
    print -u2 'seal: FAIL (manual receipt is incomplete, stale, or lacks the actual /Applications choice)'
    return 1
  }

  automatic_validation_sha256="$(shasum -a 256 "$automatic_validation" | awk '{print $1}')"
  jq -n \
    --arg run_id "$run_id" --arg tree_hash "$tree_hash" \
    --arg automatic_path "${automatic_validation#$root/}" --arg automatic_sha256 "$automatic_validation_sha256" \
    --arg package_path "Release-1.0.0-local/manifest-v1.0.json" --arg package_sha256 "$package_manifest_sha256" \
    --arg manual_path "${manual_receipt#$root/}" --arg manual_sha256 "$(shasum -a 256 "$manual_receipt" | awk '{print $1}')" \
    --arg cleanup_path "${cleanup_receipt#$root/}" --arg cleanup_sha256 "$(shasum -a 256 "$cleanup_receipt" | awk '{print $1}')" \
    --arg install_choice "$(jq -r '.applications_installation_choice' "$manual_receipt")" \
    '{schema_version:"latticelens-seal-v5",product_version:"1.0.0",build_number:100,local_only:true,run_id:$run_id,build_input_tree_sha256:$tree_hash,automatic_validation:{path:$automatic_path,sha256:$automatic_sha256},package_manifest:{path:$package_path,sha256:$package_sha256},manual_acceptance:{path:$manual_path,sha256:$manual_sha256,applications_installation_choice:$install_choice},cleanup_apply_receipt:{path:$cleanup_path,sha256:$cleanup_sha256},mandatory:{automatic_validation:true,dmg_resmoke:true,cleanup_receipt:true,manual_voiceover:true,manual_lqcd_rubric:true,manual_applications_install:true,manual_disposable_library_drill:true},optional:{developer_id:"out_of_scope",notarization:"out_of_scope",cross_machine:"out_of_scope",live_inspire:"not_run",live_llm:"not_required"},failures:0}' \
    > "$summary"
  print 'seal: PASS (no automated tests rerun; current source, package, cleanup, and manual receipt bind)'
  return 0
}

cleanup_verifier_scratch() {
  cleanup_task_owned_xcode_processes
  [[ -d "$scratch" ]] || return 0
  find "$scratch" -depth -delete 2>/dev/null || print -u2 "CLEANUP could not remove task scratch: $scratch"
}
trap cleanup_verifier_scratch EXIT
trap 'exit 143' INT TERM

[[ "$xcode_timeout_seconds" =~ '^[1-9][0-9]*$' ]] || { print -u2 'LATTICELENS_V5_XCODE_TIMEOUT_SECONDS must be a positive integer'; exit 66; }
[[ "$ui_timeout_seconds" =~ '^[1-9][0-9]*$' ]] || { print -u2 'LATTICELENS_V5_UI_TIMEOUT_SECONDS must be a positive integer'; exit 66; }
[[ "$xcresult_timeout_seconds" =~ '^[1-9][0-9]*$' ]] || { print -u2 'LATTICELENS_V5_XCRESULT_TIMEOUT_SECONDS must be a positive integer'; exit 66; }

manifest="$scratch/BuildInputManifest-v5-$run_id.json"
{
  print '{"schema_version":"latticelens-build-input-v5","files":['
  typeset -i first=1
  # `path` is a zsh special array bound to `$PATH`; using it as a loop
  # variable makes later xcodebuild invocations search the source manifest
  # as an executable path.  Keep build inputs in an ordinary identifier.
  # Sort the complete union, not merely the explicitly listed root files.
  # This tree hash is the provenance boundary between validation and package.
  typeset -a build_input_files
  build_input_files=("${(@f)$( { find Sources Tests Scripts Assets Assets.xcassets LatticeLens.xcodeproj -type f -print 2>/dev/null; print -l Package.swift README.md CHANGELOG.md AppIcon-master.svg AppIcon-contact-sheet.png; } | LC_ALL=C sort -u)}")
  for input_file in "${build_input_files[@]}"; do
    [[ -f "$input_file" ]] || continue
    file_sha256="$(shasum -a 256 "$input_file" | awk '{print $1}')"
    (( first )) || print ','
    first=0
    jq -cn --arg input_path "$input_file" --arg sha256 "$file_sha256" '{path:$input_path,sha256:$sha256}'
  done
  print ']}'
} > "$manifest"
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
' "$manifest" >/dev/null; then
  print -u2 'build_inputs: FAIL (manifest is empty, malformed, or does not cover every required v5 input class)'
  exit 65
fi
tree_hash="$(shasum -a 256 "$manifest" | awk '{print $1}')"

if [[ "$mode" == "--seal-only" ]]; then
  if seal_only; then
    print -- "summary: $summary"
    exit 0
  fi
  jq -n --arg run_id "$run_id" --arg tree_hash "$tree_hash" \
    '{schema_version:"latticelens-seal-v5",product_version:"1.0.0",build_number:100,local_only:true,run_id:$run_id,build_input_tree_sha256:$tree_hash,failures:1}' > "$summary"
  print -- "summary: $summary"
  exit 1
fi

benchmark_output="$scratch/benchmark-v5.json"
benchmark_root="$scratch/benchmark-disk"
swiftpm=false
# Keep the full host-free suite free of external-store effects even when this
# verifier was itself invoked with an authorized migration path.  The only
# process allowed to receive those paths is the later, separately audited
# migration helper.  Consequently this suite must report exactly its one
# named opt-in skip.
if run_gate swiftpm env -u LATTICELENS_V5_DISPOSABLE_V7_STORE -u LATTICELENS_V5_DISPOSABLE_DRILL_ROOT -u LATTICELENS_V5_DISPOSABLE_SOURCE_ORIGIN \
  LATTICELENS_RUN_V4_BENCHMARK=1 LATTICELENS_V4_BENCHMARK_OUTPUT="$benchmark_output" LATTICELENS_V4_BENCHMARK_ROOT="$benchmark_root" swift test; then
  if swiftpm_has_only_expected_opt_in_skip; then
    swiftpm=true
  else
    print -u2 'swiftpm: FAIL (expected exactly the user-authorized V7 migration drill opt-in skip)'
    failures+=1
  fi
fi
benchmark=false
if [[ "$swiftpm" == true ]] && jq -e '
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
' "$benchmark_output" >/dev/null 2>&1; then
  benchmark=true
else
  failures+=1
  print -u2 'actual_swiftdata_benchmark: FAIL (missing, malformed, or over-threshold current benchmark output)'
fi
typed_store=false
if [[ "$swiftpm" == true ]] && rg -q "testV8StagedMigrationMakesTypedRowsActiveAndKeepsV7SourceByteStable.*passed" "$scratch/swiftpm.log" && \
   rg -q "testV8MigrationCrashInjectionFailsClosedOrRecoversOnlyActivatedTarget.*passed" "$scratch/swiftpm.log" && \
   rg -q "testV9TypedStoreSearchUsesDurableIncrementalPaperTokenRows.*passed" "$scratch/swiftpm.log"; then
  typed_store=true
else
  failures+=1
  print -u2 'typed_store: FAIL (missing V7-to-V8 typed migration or crash-recovery evidence)'
fi
swiftpm_release=false; run_gate swiftpm_release swift build -c release && swiftpm_release=true
xcode_common=( -project LatticeLens.xcodeproj -scheme LatticeLens -destination 'platform=macOS,arch=arm64'
               -derivedDataPath "$scratch/DerivedData" CODE_SIGNING_ALLOWED=NO
               SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_STRICT_CONCURRENCY=complete )
# Keep the host-free XCTest gate independent from the UI-test bundle.  The
# product scheme deliberately contains both testables for interactive Xcode
# use, whereas this shared unit scheme has only `LatticeLensTests`; otherwise
# Xcode can construct a UI-test build graph despite `-only-testing`.
xcode_unit_common=( -project LatticeLens.xcodeproj -scheme LatticeLens-Unit -destination 'platform=macOS,arch=arm64'
                    -derivedDataPath "$scratch/DerivedData" CODE_SIGNING_ALLOWED=NO
                    ONLY_ACTIVE_ARCH=YES SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_STRICT_CONCURRENCY=complete )
# UI XCTest has its own checked-in fixture scheme.  Its `UIFixture` build
# configuration gives the launched app/test bundle distinct fixture-only
# identifiers and process-local environment defaults.  Running the UI target
# through the general app scheme produced an automation-host failure before a
# product test began, despite the same test passing through this scheme in
# graphical Xcode.  Apple marks synchronous XCUIElement APIs MainActor in the
# current SDK, while XCTest rejects waiting/clicking on that actor at runtime.
# The UI-test target is deliberately Swift 5/minimal-concurrency with a
# `@preconcurrency import XCTest` compatibility boundary; the app and unit
# targets remain strict-complete.  Keep build/analyze/unit on the product
# scheme above, but run normal and large fixture UI evidence through the
# actual UI scheme.
ui_xcode=( -project LatticeLens.xcodeproj -scheme LatticeLens-UIFixture -destination 'platform=macOS,arch=arm64'
           -derivedDataPath "$scratch/DerivedData" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
           ONLY_ACTIVE_ARCH=YES SWIFT_TREAT_WARNINGS_AS_ERRORS=YES )
# The fixture target has a broader developer regression suite.  For this
# final same-Mac release, the user approved a single non-repeating UI delta
# gate containing only the two changed/high-risk scrolling paths: Sync Center
# and the long Settings model/terminology form.  The unrelated virtualized
# author-selection regression is deliberately not repeated here; its larger
# manual reachability observation remains separately recorded.  Window-size
# observation also remains a separately recorded manual P0 fact.  Each case
# is executed through a separate Xcode
# invocation below because a multi-case macOS runner intermittently times out
# while enabling automation mode before it starts any test.
normal_ui_test_identifiers=(
  'LatticeLensUITests/LatticeLensUITests/testFixtureSyncCenterExposesDurableLocalJobSummary'
)
large_ui_test_identifiers=(
  'LatticeLensUITests/LatticeLensUITests/testLargeFixtureSettingsKeepsModelsAndTerminologyReachableInDraft'
)
normal_ui_case_count=${#normal_ui_test_identifiers}
large_ui_case_count=${#large_ui_test_identifiers}
xcode_build_analyze=false
xcode_debug=false; run_xcode_gate xcode_debug "$xcode_timeout_seconds" xcodebuild "${xcode_common[@]}" -configuration Debug build -quiet && xcode_debug=true
xcode_release=false; run_xcode_gate xcode_release "$xcode_timeout_seconds" xcodebuild "${xcode_common[@]}" -configuration Release build -quiet && xcode_release=true
xcode_analyze=false; run_xcode_gate xcode_analyze "$xcode_timeout_seconds" xcodebuild "${xcode_common[@]}" -configuration Debug analyze -quiet && xcode_analyze=true
[[ "$xcode_debug" == true && "$xcode_release" == true && "$xcode_analyze" == true ]] && xcode_build_analyze=true
xcode_unit_result="$scratch/xcode-unit.xcresult"
xcode_unit=false
unit_xctestrun=''
# Keep compiling and executing as independently observable Xcode actions.
# On this macOS/Xcode combination the monolithic `xcodebuild test` path has
# previously left a completed build graph without a usable XCTest result.  A
# fresh xctestrun plus test-without-building produces the actual current
# XCTest bundle that the result parser validates below; no historical result
# or SwiftPM substitute is accepted.
if run_xcode_gate xcode_unit_build "$xcode_timeout_seconds" env LATTICELENS_TEST_STORE_ROOT="$scratch/xcode-unit-store" \
  xcodebuild "${xcode_unit_common[@]}" build-for-testing -quiet; then
  unit_xctestrun="$(xctestrun_for_scheme "$scratch/DerivedData" LatticeLens-Unit || true)"
  if [[ -n "$unit_xctestrun" ]] && \
     run_xcode_gate xcode_unit_run "$xcode_timeout_seconds" env LATTICELENS_TEST_STORE_ROOT="$scratch/xcode-unit-store" \
       xcodebuild test-without-building -xctestrun "$unit_xctestrun" -destination 'platform=macOS,arch=arm64' \
       -resultBundlePath "$xcode_unit_result" -only-testing:LatticeLensTests -quiet && \
     current_unit_xcresult_is_complete "$xcode_unit_result" "$scratch/xcode-unit-summary.json"; then
    xcode_unit=true
  else
    print -u2 'xcode_unit_result: FAIL (two-stage unit execution did not produce the required current complete xcresult)'
    failures+=1
  fi
else
  print -u2 'xcode_unit_result: FAIL (build-for-testing did not produce a fresh xctestrun)'
  failures+=1
fi
ui_normal=false
normal_ui_xctestrun=''
# UI execution uses the same explicit two-stage contract as the unit target:
# a fresh fixture-scheme xctestrun must exist before a separate XCTest action
# may produce the mandatory result.  A result bundle is required for every
# selected case; neither a build-only action nor a prior result may substitute.
if run_xcode_gate ui_normal_build "$ui_timeout_seconds" env LATTICELENS_USE_FIXTURES=1 \
  xcodebuild "${ui_xcode[@]}" build-for-testing -quiet; then
  normal_ui_xctestrun="$(xctestrun_for_scheme "$scratch/DerivedData" LatticeLens-UIFixture || true)"
  normal_ui_runs_complete=true
  typeset -i normal_ui_case_index=0
  for ui_test_identifier in "${normal_ui_test_identifiers[@]}"; do
    (( normal_ui_case_index += 1 ))
    normal_ui_result="$scratch/ui-normal-$normal_ui_case_index.xcresult"
    if [[ -z "$normal_ui_xctestrun" ]] || \
       ! run_xcode_gate "ui_normal_run_$normal_ui_case_index" "$ui_timeout_seconds" env LATTICELENS_USE_FIXTURES=1 \
         xcodebuild test-without-building -xctestrun "$normal_ui_xctestrun" -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
         -resultBundlePath "$normal_ui_result" "-only-testing:$ui_test_identifier" -quiet; then
      normal_ui_runs_complete=false
      break
    fi
    if ! current_ui_xcresult_is_complete "$normal_ui_result" "$scratch/ui-normal-$normal_ui_case_index-summary.json" 1; then
      failures+=1
      normal_ui_runs_complete=false
      print -u2 "ui_normal_result: FAIL (selected case $normal_ui_case_index did not produce a complete current xcresult)"
      break
    fi
  done
  if [[ "$normal_ui_runs_complete" == true ]]; then
    ui_normal=true
  else
    print -u2 'ui_normal_result: FAIL (a selected fixture UI case did not complete)'
  fi
else
  print -u2 'ui_normal_result: FAIL (fixture build-for-testing did not produce a fresh xctestrun)'
  failures+=1
fi
ui_large_xcode=( -project LatticeLens.xcodeproj -scheme LatticeLens-UIFixture -destination 'platform=macOS,arch=arm64'
                 -derivedDataPath "$scratch/DerivedDataLarge" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
                 ONLY_ACTIVE_ARCH=YES SWIFT_TREAT_WARNINGS_AS_ERRORS=YES )
ui_large=false
large_ui_xctestrun=''
if run_xcode_gate ui_large_build "$ui_timeout_seconds" env LATTICELENS_USE_FIXTURES=1 LATTICELENS_LARGE_UI_FIXTURE=1 \
  xcodebuild "${ui_large_xcode[@]}" build-for-testing -quiet; then
  large_ui_xctestrun="$(xctestrun_for_scheme "$scratch/DerivedDataLarge" LatticeLens-UIFixture || true)"
  large_ui_runs_complete=true
  typeset -i large_ui_case_index=0
  for ui_test_identifier in "${large_ui_test_identifiers[@]}"; do
    (( large_ui_case_index += 1 ))
    large_ui_result="$scratch/ui-large-$large_ui_case_index.xcresult"
    if [[ -z "$large_ui_xctestrun" ]] || \
       ! run_xcode_gate "ui_large_run_$large_ui_case_index" "$ui_timeout_seconds" env LATTICELENS_USE_FIXTURES=1 LATTICELENS_LARGE_UI_FIXTURE=1 \
         xcodebuild test-without-building -xctestrun "$large_ui_xctestrun" -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
         -resultBundlePath "$large_ui_result" "-only-testing:$ui_test_identifier" -quiet; then
      large_ui_runs_complete=false
      break
    fi
    if ! current_ui_xcresult_is_complete "$large_ui_result" "$scratch/ui-large-$large_ui_case_index-summary.json" 1; then
      failures+=1
      large_ui_runs_complete=false
      print -u2 "ui_large_result: FAIL (selected case $large_ui_case_index did not produce a complete current xcresult)"
      break
    fi
  done
  if [[ "$large_ui_runs_complete" == true ]]; then
    ui_large=true
  else
    print -u2 'ui_large_result: FAIL (a selected large-fixture UI case did not complete)'
  fi
else
  print -u2 'ui_large_result: FAIL (large-fixture build-for-testing did not produce a fresh xctestrun)'
  failures+=1
fi
icon_version=false; run_gate icon_version verify_icon_version && icon_version=true

# This must never be synthesized from an empty/default store.  The caller has
# to name every migration input explicitly for this *particular* verification
# run.  A supplied source may be a synthetic benchmark family, but its origin
# remains recorded as such and is never promoted into a claim about an active
# user library.  The helper rejects source/output overlap, symlinks, live
# writers and a non-empty output root before SwiftData is opened.
migration_drill=false
migration_evidence_origin='not_run'
migration_evidence_store='not_run'
migration_evidence_sha256='not_run'
migration_source="${LATTICELENS_V5_DISPOSABLE_V7_STORE:-}"
migration_output_root="${LATTICELENS_V5_DISPOSABLE_DRILL_ROOT:-}"
migration_source_origin="${LATTICELENS_V5_DISPOSABLE_SOURCE_ORIGIN:-}"
if [[ -n "$migration_source" || -n "$migration_output_root" || -n "$migration_source_origin" ]]; then
  if [[ -z "$migration_source" || -z "$migration_output_root" || -z "$migration_source_origin" ]]; then
    failures+=1
    print -u2 'migration_backup_rollback: FAIL (set LATTICELENS_V5_DISPOSABLE_V7_STORE, LATTICELENS_V5_DISPOSABLE_DRILL_ROOT, and LATTICELENS_V5_DISPOSABLE_SOURCE_ORIGIN together)'
  elif run_gate migration_backup_rollback zsh Scripts/migration_v7_disposable_drill.sh \
      --source "$migration_source" --output-root "$migration_output_root" --source-origin "$migration_source_origin"; then
    migration_evidence="$(find "$migration_output_root" -mindepth 2 -maxdepth 2 -type f -name 'migration-v7-disposable-drill.json' -print -quit 2>/dev/null || true)"
    if [[ -n "$migration_evidence" ]] && jq -e --arg origin "$migration_source_origin" '
        .sourceOrigin == $origin and
        (.journal.phase == "activated") and
        (.journal.preSummary == .journal.postSummary) and
        (.semanticSummary == .journal.postSummary) and
        (.finalSchemaVersion == 9) and
        (.searchIndexCurrent == true) and
        ((.sourceFamilyHashes | type) == "object") and
        ((.sourceFamilyHashes | length) > 0)
      ' "$migration_evidence" >/dev/null 2>&1; then
      migration_drill=true
      migration_evidence_origin="$(jq -r '.sourceOrigin' "$migration_evidence")"
      migration_evidence_store="$(jq -r '.sourceStoreName' "$migration_evidence")"
      migration_evidence_sha256="$(shasum -a 256 "$migration_evidence" | awk '{print $1}')"
    else
      failures+=1
      print -u2 'migration_backup_rollback: FAIL (helper exited 0 but its sanitized evidence is missing or semantically inconsistent)'
    fi
  else
    failures+=1
    print -u2 'migration_backup_rollback: FAIL (authorized disposable drill command failed)'
  fi
else
  failures+=1
  print -u2 'migration_backup_rollback: BLOCKED (no user-authorized disposable library copy path supplied to this verifier run)'
fi
physics_validator=false
if [[ "$swiftpm" == true ]] && swiftpm_contract_tests_passed \
  testPhysicsTruthTableDoesNotFabricateCaveatEvidence \
  testPhysicsValidatorRequiresValueAndUnitInSameAnchorWindow \
  testNumericCorpusRejectsYearsReferencesEquationsAndPagesWithoutDiscardingLatticeForms \
  testCrossPaperPhysicsCellNeedsCurrentContextAndForeignValueAnchor; then
  physics_validator=true
else
  failures+=1
  print -u2 'physics_validator: FAIL (current v5 truth-table/numeric corpus XCTest evidence is incomplete)'
fi
radar=false
if [[ "$swiftpm" == true ]] && swiftpm_contract_tests_passed \
  testRadarDiffClassifiesAddedRemovedAndModifiedWithFieldHashes \
  testRadarPausePublishesAndPersistsTheSameDurableQueryState \
  testRadarSemanticPipelinePreservesUnknownCitationWithoutLegacyEventKinds \
  testSavedRadarQueryRefreshPersistsBatchSnapshotAndEventsWithoutAuthorLink; then
  radar=true
else
  failures+=1
  print -u2 'radar: FAIL (current semantic-diff/dedup/durable-query XCTest evidence is incomplete)'
fi
compare=false
if [[ "$swiftpm" == true ]] && swiftpm_contract_tests_passed \
  testCompareExtractorReturnsMissingInsteadOfGuessing \
  testCompareLocalExtractorAtomicallyReplacesOnlyFullyValidatedMatrix \
  testCrossPaperPhysicsCellNeedsCurrentContextAndForeignValueAnchor \
  testV8WorkbenchMutationsUseTypedRowsAndAtomicPhysicsReplacement; then
  compare=true
else
  failures+=1
  print -u2 'compare: FAIL (current frozen/validated atomic-matrix XCTest evidence is incomplete)'
fi
notebook=false
if [[ "$swiftpm" == true ]] && swiftpm_contract_tests_passed \
  testPDFKitSelectionLocatorRequiresOneExactPageOccurrence \
  testV8NotebookEntryPersistsOrderedMultiAnchorLinksAcrossRelaunch \
  testNotebookRejectsForeignAndStaleAnchorsAndEntryDeleteCascadesLinks \
  testNotebookImportMergesOnlyExplicitlyAcceptedFieldsAndAuditsConsent; then
  notebook=true
else
  failures+=1
  print -u2 'notebook: FAIL (current selection/multi-anchor/import XCTest evidence is incomplete)'
fi
bundle=false
if [[ "$swiftpm" == true ]] && swiftpm_contract_tests_passed \
  testBundleManifestHashAndTamperDetectionContract \
  testResearchBundleVerifyDryRunAndRestoreToNewTarget \
  testResearchBundleTypedRestoreBuildsVerifiedV9StagingStoreWithoutActiveOverwrite; then
  bundle=true
else
  failures+=1
  print -u2 'bundle: FAIL (current verified staging-restore XCTest evidence is incomplete)'
fi
# Packaging is deliberately two phase.  A package cannot be a prerequisite of
# the validation record it consumes.  This receipt freezes the current
# automatic gates and tree hash; the packager recomputes that tree and rejects
# source drift before it builds a DMG.
prepackage_ready=true
for prepackage_gate in "$swiftpm" "$benchmark" "$swiftpm_release" "$xcode_build_analyze" "$xcode_unit" "$ui_normal" "$ui_large" "$typed_store" "$migration_drill" "$physics_validator" "$radar" "$compare" "$notebook" "$bundle" "$icon_version"; do
  [[ "$prepackage_gate" == true ]] || prepackage_ready=false
done
benchmark_warm_search="$(jq -c '.warm_search_p95_ms // null' "$benchmark_output" 2>/dev/null || print null)"
benchmark_cold_open="$(jq -c '.disk_backed.cold_open_p95_ms // null' "$benchmark_output" 2>/dev/null || print null)"
benchmark_single_mutation="$(jq -c '.single_row_mutation_p95_ms // null' "$benchmark_output" 2>/dev/null || print null)"
benchmark_v7_warm_search="$(jq -c '.v7_active_domain.warm_search_p95_ms // null' "$benchmark_output" 2>/dev/null || print null)"
benchmark_v9_final_typed="$(jq -c '.v9_final_typed // null' "$benchmark_output" 2>/dev/null || print null)"
prepackage_summary="$scratch/prepackage-validation-v5.json"
jq -n \
  --arg run_id "$run_id" --arg tree_hash "$tree_hash" \
  --arg source_origin "$migration_evidence_origin" --arg source_store "$migration_evidence_store" --arg migration_sha256 "$migration_evidence_sha256" \
  --arg ui_evidence_scope 'selected_ui_delta_once_per_case' --argjson normal_ui_case_count "$normal_ui_case_count" --argjson large_ui_case_count "$large_ui_case_count" \
  --argjson swiftpm "$swiftpm" --argjson benchmark "$benchmark" --argjson swiftpm_release "$swiftpm_release" \
  --argjson xcode_build_analyze "$xcode_build_analyze" --argjson xcode_unit "$xcode_unit" --argjson ui_normal "$ui_normal" --argjson ui_large "$ui_large" \
  --argjson typed_store "$typed_store" --argjson migration_drill "$migration_drill" --argjson physics_validator "$physics_validator" --argjson radar "$radar" \
  --argjson compare "$compare" --argjson notebook "$notebook" --argjson bundle "$bundle" --argjson icon_version "$icon_version" --argjson eligible "$prepackage_ready" \
  --argjson warm_search "$benchmark_warm_search" --argjson cold_open "$benchmark_cold_open" --argjson single_mutation "$benchmark_single_mutation" --argjson v7_warm_search "$benchmark_v7_warm_search" --argjson v9_final_typed "$benchmark_v9_final_typed" \
  '{schema_version:"latticelens-prepackage-v5",product_version:"1.0.0",build_number:100,local_only:true,run_id:$run_id,build_input_tree_sha256:$tree_hash,prepackage_eligible:$eligible,ui_evidence:{scope:$ui_evidence_scope,normal_case_count:$normal_ui_case_count,large_case_count:$large_ui_case_count},mandatory:{swiftpm:$swiftpm,actual_swiftdata_benchmark:$benchmark,swiftpm_release:$swiftpm_release,xcode_build_analyze:$xcode_build_analyze,xcode_unit:$xcode_unit,ui_normal:$ui_normal,ui_large_scroll_accessibility:$ui_large,typed_store:$typed_store,migration_backup_rollback:$migration_drill,physics_validator:$physics_validator,radar:$radar,compare:$compare,notebook:$notebook,bundle:$bundle,icon_version_resources:$icon_version},migration_evidence:{source_origin:$source_origin,source_store_name:$source_store,sha256:$migration_sha256},benchmarks:{legacy_v6_warm_search_p95_ms:$warm_search,legacy_v6_disk_cold_open_p95_ms:$cold_open,legacy_v6_disk_single_row_mutation_p95_ms:$single_mutation,compatibility_v7_warm_search_p95_ms:$v7_warm_search,v9_final_typed:$v9_final_typed}}' \
  > "$prepackage_summary"

package_status=false
release_dir="$root/Release-1.0.0-local"
package_manifest="$release_dir/manifest-v1.0.json"
package_manifest_relative='not_run'
package_manifest_sha256='not_run'
verify_existing_package() {
  [[ -d "$release_dir" && -f "$package_manifest" ]] || return 1
  jq -e --arg tree_hash "$tree_hash" '
    .schema_version == "latticelens-package-manifest-v1.0" and
    .artifact_class == "same_mac_local_ad_hoc" and .product_version == "1.0.0" and .build_number == 100 and
    .signature_class == "ad_hoc_local" and .developer_id == false and .notarized == false and .dmg_smoke == "passed" and
    .build_input_tree_sha256 == $tree_hash and
    (.artifacts.dmg.sha256 | test("^[0-9a-f]{64}$")) and (.artifacts.dsym.sha256 | test("^[0-9a-f]{64}$"))
  ' "$package_manifest" >/dev/null 2>&1 && zsh Scripts/smoke_v1_local_dmg.sh "$release_dir" >"$scratch/dmg-smoke.log" 2>&1
}
if [[ "$prepackage_ready" == true ]]; then
  if [[ -e "$release_dir" ]]; then
    if verify_existing_package; then package_status=true
    else failures+=1; print -u2 'dmg_smoke: FAIL (existing Release-1.0.0-local is malformed, source-drifted, or fails independent smoke)' ; fi
  elif zsh Scripts/package_v1_local_dmg.sh "$prepackage_summary" "$benchmark_output" >"$scratch/package.log" 2>&1 && verify_existing_package; then
    package_status=true
  else
    failures+=1
    print -u2 'dmg_smoke: FAIL (prepackage gates passed but package/mount/copy-launch evidence did not verify)'
  fi
else
  failures+=1
  print -u2 'dmg_smoke: BLOCKED (one or more current automatic prepackage gates are false; package was not attempted)'
fi
if [[ "$package_status" == true ]]; then
  package_manifest_relative="${package_manifest#$root/}"
  package_manifest_sha256="$(shasum -a 256 "$package_manifest" | awk '{print $1}')"
fi

# Dry-run cleanup output is a candidate list, not permission to delete.  Do
# not overwrite the existing dry-run manifest.  A final run requires an
# explicit project-local receipt supplied by the user after whitelist review.
cleanup=false
cleanup_status='not_authorized'
cleanup_approval="${LATTICELENS_V5_APPROVED_CLEANUP_MANIFEST:-}"
cleanup_approval_relative='not_supplied'
cleanup_approval_sha256='not_run'
cleanup_receipt_relative='not_run'
cleanup_receipt_sha256='not_run'
cleanup_deleted_bytes='null'
if [[ -n "$cleanup_approval" ]]; then
  cleanup_approval="${cleanup_approval:A}"
  if [[ "$cleanup_approval" == "$root"/* && -f "$cleanup_approval" && ! -L "$cleanup_approval" ]] && \
     jq -e '.schema_version == "latticelens-cleanup-v1.0" and .mode == "approved_apply" and (.approved_by | type == "string" and length > 0) and (.approved_at_utc | type == "string" and length > 0) and (.allowed_relative_paths | type == "array") and (.allowed_relative_paths | all(type == "string" and length > 0 and (startswith("/") | not) and (contains("..") | not)))' "$cleanup_approval" >/dev/null 2>&1; then
    cleanup_approval_relative="${cleanup_approval#$root/}"
    cleanup_approval_sha256="$(shasum -a 256 "$cleanup_approval" | awk '{print $1}')"
    cleanup_receipt="$root/cleanup-apply-receipt-v1.0-$run_id.json"
    approved_paths_json="$(jq -c '.allowed_relative_paths' "$cleanup_approval")"
    if zsh Scripts/apply_v1_cleanup.sh --approved-manifest "$cleanup_approval" --receipt "$cleanup_receipt" >"$scratch/cleanup-apply.log" 2>&1 && \
       [[ -f "$cleanup_receipt" && ! -L "$cleanup_receipt" ]] && \
       jq -e --arg approval_sha256 "$cleanup_approval_sha256" --argjson approved_paths "$approved_paths_json" '
         .schema_version == "latticelens-cleanup-apply-receipt-v1.0" and
         .result == "applied" and
         .approvedManifestSHA256 == $approval_sha256 and
         (.deletedBytes | type == "number" and . >= 0) and
         (.deletedRelativePaths | type == "array" and all(type == "string" and length > 0 and (startswith("/") | not) and (contains("..") | not))) and
         (.alreadyAbsentRelativePaths | type == "array" and all(type == "string" and length > 0 and (startswith("/") | not) and (contains("..") | not))) and
         (([.deletedRelativePaths[], .alreadyAbsentRelativePaths[]] | sort | unique) == ($approved_paths | sort | unique))
       ' "$cleanup_receipt" >/dev/null 2>&1; then
      cleanup=true
      cleanup_status='applied'
      cleanup_receipt_relative="${cleanup_receipt#$root/}"
      cleanup_receipt_sha256="$(shasum -a 256 "$cleanup_receipt" | awk '{print $1}')"
      cleanup_deleted_bytes="$(jq -c '.deletedBytes' "$cleanup_receipt")"
    else
      failures+=1
      cleanup_status='apply_failed_or_invalid_receipt'
      print -u2 'cleanup: FAIL (approved cleanup did not produce a valid applied receipt; inspect the task log and preserve all remaining targets)'
    fi
  else
    failures+=1
    cleanup_status='invalid_approval_receipt'
    print -u2 'cleanup: FAIL (approval receipt must be a non-symlink project-local approved_apply manifest)'
  fi
else
  failures+=1
  print -u2 'cleanup: BLOCKED (set LATTICELENS_V5_APPROVED_CLEANUP_MANIFEST after whitelist review; dry-run is not approval)'
fi

# UI automation cannot stand in for the manual VoiceOver, LQCD provenance and
# /Applications rollback observations.  A compact receipt must bind those
# observations to the immutable package manifest that was actually mounted.
manual_voiceover=false
manual_lqcd=false
manual_applications=false
manual_disposable=false
manual_status='not_supplied'
manual_receipt="${LATTICELENS_V5_MANUAL_ACCEPTANCE_JSON:-}"
if [[ -n "$manual_receipt" ]]; then
  manual_receipt="${manual_receipt:A}"
  if [[ "$manual_receipt" == "$root"/* && -f "$manual_receipt" && ! -L "$manual_receipt" && "$package_status" == true ]] && \
     jq -e --arg package_sha256 "$package_manifest_sha256" '.schema_version == "latticelens-manual-acceptance-v5" and .package_manifest_sha256 == $package_sha256 and .mandatory.voiceover == true and .mandatory.lqcd_rubric == true and .mandatory.applications_install == true and .mandatory.disposable_library_drill == true and (.applications_installation_choice == "preserved_and_renamed_old_app" or .applications_installation_choice == "replaced_after_verified_backup" or .applications_installation_choice == "no_old_app")' "$manual_receipt" >/dev/null 2>&1; then
    manual_voiceover=true
    manual_lqcd=true
    manual_applications=true
    manual_disposable=true
    manual_status='verified_receipt'
  else
    failures+=1
    manual_status='invalid_or_stale_receipt'
    print -u2 'manual: FAIL (acceptance receipt is incomplete, stale, outside the project, or does not bind to this package)'
  fi
else
  failures+=1
  print -u2 'manual: BLOCKED (no current VoiceOver/LQCD/install/disposable-library receipt supplied)'
fi

jq -n \
  --arg run_id "$run_id" --arg tree_hash "$tree_hash" --arg source_origin "$migration_evidence_origin" --arg source_store "$migration_evidence_store" --arg migration_sha256 "$migration_evidence_sha256" \
  --arg package_manifest "$package_manifest_relative" --arg package_manifest_sha256 "$package_manifest_sha256" --arg cleanup_status "$cleanup_status" --arg cleanup_approval "$cleanup_approval_relative" --arg cleanup_approval_sha256 "$cleanup_approval_sha256" --arg cleanup_receipt "$cleanup_receipt_relative" --arg cleanup_receipt_sha256 "$cleanup_receipt_sha256" --arg manual_status "$manual_status" \
  --arg ui_evidence_scope 'selected_ui_delta_once_per_case' --argjson normal_ui_case_count "$normal_ui_case_count" --argjson large_ui_case_count "$large_ui_case_count" \
  --argjson timeout_seconds "$xcode_timeout_seconds" --argjson ui_timeout_seconds "$ui_timeout_seconds" \
  --argjson cleanup_deleted_bytes "$cleanup_deleted_bytes" --argjson swiftpm "$swiftpm" --argjson benchmark "$benchmark" --argjson swiftpm_release "$swiftpm_release" --argjson xcode_build_analyze "$xcode_build_analyze" --argjson xcode_unit "$xcode_unit" --argjson ui_normal "$ui_normal" --argjson ui_large "$ui_large" --argjson typed_store "$typed_store" --argjson migration_drill "$migration_drill" --argjson physics_validator "$physics_validator" --argjson radar "$radar" --argjson compare "$compare" --argjson notebook "$notebook" --argjson bundle "$bundle" --argjson icon_version "$icon_version" --argjson package_status "$package_status" --argjson cleanup "$cleanup" --argjson manual_voiceover "$manual_voiceover" --argjson manual_lqcd "$manual_lqcd" --argjson manual_applications "$manual_applications" --argjson manual_disposable "$manual_disposable" --argjson warm_search "$benchmark_warm_search" --argjson cold_open "$benchmark_cold_open" --argjson single_mutation "$benchmark_single_mutation" --argjson v7_warm_search "$benchmark_v7_warm_search" --argjson failures "$failures" \
  '{schema_version:"latticelens-verify-v5",product_version:"1.0.0",build_number:100,local_only:true,run_id:$run_id,xcode_timeout_seconds:$timeout_seconds,ui_timeout_seconds:$ui_timeout_seconds,build_input_tree_sha256:$tree_hash,ui_evidence:{scope:$ui_evidence_scope,normal_case_count:$normal_ui_case_count,large_case_count:$large_ui_case_count},mandatory:{swiftpm:$swiftpm,actual_swiftdata_benchmark:$benchmark,swiftpm_release:$swiftpm_release,xcode_build_analyze:$xcode_build_analyze,xcode_unit:$xcode_unit,ui_normal:$ui_normal,ui_large_scroll_accessibility:$ui_large,typed_store:$typed_store,migration_backup_rollback:$migration_drill,physics_validator:$physics_validator,radar:$radar,compare:$compare,notebook:$notebook,bundle:$bundle,icon_version_resources:$icon_version,dmg_smoke:$package_status,cleanup:$cleanup},migration_evidence:{source_origin:$source_origin,source_store_name:$source_store,sha256:$migration_sha256},benchmarks:{warm_search_p95_ms:$warm_search,disk_cold_open_p95_ms:$cold_open,disk_single_row_mutation_p95_ms:$single_mutation,v7_warm_search_p95_ms:$v7_warm_search},artifacts:{package_manifest:{path:$package_manifest,sha256:$package_manifest_sha256}},manual:{voiceover:$manual_voiceover,lqcd_rubric:$manual_lqcd,applications_install:$manual_applications,disposable_library_drill:$manual_disposable,status:$manual_status},cleanup:{status:$cleanup_status,approvalManifest:{path:$cleanup_approval,sha256:$cleanup_approval_sha256},applyReceipt:{path:$cleanup_receipt,sha256:$cleanup_receipt_sha256},deletedBytes:$cleanup_deleted_bytes},optional:{live_inspire:"not_run",live_llm:"not_required",developer_id:"out_of_scope",notarization:"out_of_scope",cross_machine:"out_of_scope"},failures:$failures,task_scratch:"removed_after_summary"}' \
  > "$summary"
print -- "summary: $summary"
exit $(( failures == 0 ? 0 : 1 ))
