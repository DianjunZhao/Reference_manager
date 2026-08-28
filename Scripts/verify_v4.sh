#!/bin/zsh
# LatticeLens v4 local verifier.
#
# This entry point is intentionally fail-closed.  It runs the host-free local
# contracts, the actual SwiftData benchmark, Xcode build/unit gates, and then
# attempts the fixture-isolated XCUIApplication target.  A readable result
# bundle with a runner crash is recorded as executed=false; it is never
# promoted to a UI pass.  No live INSPIRE request, LLM POST, CloudKit action,
# Keychain inspection, signing or notarization is performed here.
set -u
set -o pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
local_only=true
keep_evidence=false
skip_ui=false
for arg in "$@"; do
  case "$arg" in
    --local-only) local_only=true ;;
    --keep-evidence) keep_evidence=true ;;
    --skip-ui) skip_ui=true ;;
    -h|--help)
      print "usage: zsh Scripts/verify_v4.sh [--local-only] [--skip-ui] [--keep-evidence]"
      exit 0
      ;;
    *) print -u2 "unknown option: $arg"; exit 2 ;;
  esac
done

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
scratch="$project_root/.codex-task-tmp-v4-verify-$run_id"
if [[ -e "$scratch" ]]; then
  print -u2 "Refusing to reuse existing scratch path: $scratch"
  exit 2
fi

task_owned_xcode_pids() {
  # Every Xcode action in this verifier uses the exact scratch-derived path.
  # A matching process therefore belongs to this invocation, not a pre-existing
  # Xcode, app, or another verifier invocation.
  /bin/ps -axo pid=,command= | /usr/bin/awk -v marker="$scratch/derived/" '
    index($0, marker) && ($0 ~ /xcodebuild/ || $0 ~ /LatticeLens.*Tests-Runner/ || $0 ~ /LatticeLens\.app\/Contents\/MacOS\/LatticeLens/) { print $1 }
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
  # Rescan after the grace period rather than reusing a PID which might have
  # exited and been recycled by the OS.
  listing="$(task_owned_xcode_pids)"
  [[ -n "$listing" ]] || return 0
  pids=("${(@f)listing}")
  print -u2 "CLEANUP force-terminating remaining task-owned Xcode-derived process(es): ${pids[*]}"
  /bin/kill -KILL "${pids[@]}" 2>/dev/null || true
}

typeset -i cleanup_ran=0

cleanup() {
  (( cleanup_ran == 0 )) || return 0
  cleanup_ran=1
  cleanup_task_owned_xcode_processes
  if $keep_evidence; then
    print -u2 "KEEP_EVIDENCE=$scratch"
    return 0
  fi
  [[ -d "$scratch" ]] || return 0
  find "$scratch" -depth -type f -exec /bin/unlink {} ';'
  find "$scratch" -depth -type l -exec /bin/unlink {} ';'
  find "$scratch" -depth -type d -exec /bin/rmdir {} '+' 2>/dev/null || true
}
# An interrupted verification must not continue on to a second XCTest attempt.
# This also restricts cleanup to the scratch directory created by this exact
# invocation; historical evidence is never selected as a fallback.
trap cleanup EXIT
trap 'cleanup; exit 143' INT TERM

mkdir -p "$scratch/persistence" "$scratch/derived"
export LATTICELENS_TEST_STORE_ROOT="$scratch/persistence"
cd "$project_root"
ui_business_cases_required="$(rg -o 'func test[A-Za-z0-9_]+' Tests/LatticeLensUITests/LatticeLensUITests.swift | wc -l | tr -d '[:space:]')"

typeset -i failures=0
typeset -i swiftpm_tests=0 swiftpm_release=0 xcode_debug=0 xcode_unit=0 xcode_release=0 xcode_analyze=0 xcode_build_for_testing=0
typeset -i benchmark=0 ui_compiled=0 ui_executed=0 ui_readable=0 ui_runtime=0
typeset -i swiftpm_test_count=0 swiftpm_skipped=0 swiftpm_failed=0
typeset -i ui_total=0 ui_passed=0 ui_failed=0 ui_skipped=0 ui_business_cases_passed=0 ui_business_cases_required
typeset -i ui_attempts_executed=0 ui_successful_attempt=0
typeset -i ui_failure_recorded=0
typeset -i migration_rollback=0 benchmark_within_target=0
typeset -i benchmark_warm_p95=-1
typeset -i benchmark_cold_open_p95=-1 benchmark_single_mutation_p95=-1
typeset benchmark_backup_verified=false
typeset -i benchmark_migration_count=-1
typeset -i benchmark_v7_warm_p95=-1 benchmark_v7_cold_open_p95=-1 benchmark_v7_single_mutation_p95=-1
typeset -i benchmark_v7_authors=-1 benchmark_v7_papers=-1 benchmark_v7_links=-1 benchmark_v7_chunks=-1
typeset benchmark_v7_backup_verified=false
typeset -a failure_json=()

json_quote() { /usr/bin/jq -Rs .; }

failure_entry() {
  local name="$1" log="$2"
  local tail_text=""
  [[ -f "$log" ]] && tail_text="$(tail -n 24 "$log" 2>/dev/null || true)"
  local encoded
  encoded="$(print -rn -- "$tail_text" | json_quote)"
  failure_json+=("$(print -r -- "{\"gate\":\"$name\",\"snippet\":$encoded}")")
}

run_gate() {
  local name="$1"; shift
  local log="$scratch/$name.log"
  if "$@" >"$log" 2>&1; then
    print "PASS $name"
    return 0
  fi
  print -u2 "FAIL $name (compact evidence will be kept in validation-v4.json)"
  failures+=1
  failure_entry "$name" "$log"
  return 1
}

# Run an Xcode action in a private process group and impose a real bound on
# the entire group. `xcodebuild` can leave an XCTest runner as a descendant;
# signaling only its parent would otherwise create a task-owned orphan. A
# timeout exits 124 and writes a compact marker to the command log, so it is
# fail-closed and distinguishable from a build/test assertion failure.
run_bounded_xcode_command() {
  local timeout_seconds="$1"; shift
  /usr/bin/perl -MPOSIX -MTime::HiRes -e '
    my $timeout = shift @ARGV;
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
  ' "$timeout_seconds" "$@"
}

run_xcode_gate() {
  local name="$1"; shift
  run_gate "$name" run_bounded_xcode_command "$xcode_timeout_seconds" "$@"
  local gate_status=$?
  cleanup_task_owned_xcode_processes
  return "$gate_status"
}

parse_swiftpm_summary() {
  local values
  values="$(sed -nE 's/.*Executed ([0-9]+) tests?, with ([0-9]+) tests? skipped and ([0-9]+) failures?.*/\1 \2 \3/p' "$scratch/swiftpm_tests.log" 2>/dev/null | tail -1 || true)"
  if [[ -z "$values" ]]; then
    values="$(sed -nE 's/.*Executed ([0-9]+) tests?, with ([0-9]+) failures?.*/\1 0 \2/p' "$scratch/swiftpm_tests.log" 2>/dev/null | tail -1 || true)"
  fi
  if [[ -n "$values" ]]; then
    swiftpm_test_count="${values%% *}"
    values="${values#* }"
    swiftpm_skipped="${values%% *}"
    swiftpm_failed="${values##* }"
  fi
}

read_xcresult_summary() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  run_bounded_xcode_command "$xcresult_command_timeout_seconds" /usr/bin/xcrun xcresulttool get test-results summary --path "$path"
}

# xcodebuild can print a successful test-session footer shortly before
# xcresulttool can reopen the finalized bundle.  Do not fall back to a
# historical root-level summary during that finalization window: wait
# for the *current* bundle to become readable.  When a successful UI command
# is expected to run the entire target, require at least its declared number
# of business cases; a one-test/runner-crash bundle can never satisfy this.
read_xcresult_summary_after_finalization() {
  local path="$1" minimum_total="${2:-0}" attempts="${3:-600}"
  local candidate="" candidate_total="0" candidate_status=0 json_status=0
  local trace="$scratch/xcresult-finalization.log"
  local raw_summary="$scratch/${path:t}.last-summary.json"
  typeset -i attempt=1

  while (( attempt <= attempts )); do
    candidate_status=0
    candidate="$(read_xcresult_summary "$path" 2>>"$trace")" || candidate_status=$?
    print -rn -- "$candidate" >"$raw_summary"
    print -r -- "poll=$attempt bundle=${path:t} command_exit=$candidate_status bytes=${#candidate}" >>"$trace"
    json_status=1
    candidate_total="0"
    if [[ -n "$candidate" ]]; then
      json_status=0
      candidate_total="$(/usr/bin/jq -er '.totalTestCount // empty' "$raw_summary" 2>>"$trace")" || json_status=$?
    fi
    print -r -- "poll=$attempt bundle=${path:t} json_exit=$json_status total=$candidate_total minimum=$minimum_total" >>"$trace"
    if (( json_status == 0 )); then
      if [[ "$candidate_total" =~ '^[0-9]+$' ]] && (( candidate_total >= minimum_total )); then
        print -r -- "$candidate"
        return 0
      fi
      # A finalized but incomplete result is not going to acquire missing
      # business cases later. Return promptly so the caller records/retries it
      # as a failed attempt; only an unreadable bundle needs further polling.
      return 1
    fi
    (( attempt == attempts )) && break
    /bin/sleep 1
    (( attempt += 1 ))
  done
  return 1
}

benchmark_output="$scratch/benchmark-v4.json"
benchmark_root="$scratch/benchmark-disk"
run_gate swiftpm_tests env LATTICELENS_RUN_V4_BENCHMARK=1 LATTICELENS_V4_BENCHMARK_OUTPUT="$benchmark_output" LATTICELENS_V4_BENCHMARK_ROOT="$benchmark_root" \
  swift test --scratch-path "$scratch/swift-test"
if [[ $? -eq 0 ]]; then swiftpm_tests=1; else :; fi
parse_swiftpm_summary
if [[ $swiftpm_tests -eq 1 && -s "$benchmark_output" ]]; then
  benchmark=1
  benchmark_warm_p95="$(jq -r '.warm_search_p95_ms // .warm_search_ms // -1' "$benchmark_output")"
  benchmark_cold_open_p95="$(jq -r '.disk_backed.cold_open_p95_ms // -1' "$benchmark_output")"
  benchmark_single_mutation_p95="$(jq -r '.single_row_mutation_p95_ms // .single_row_mutation_ms // -1' "$benchmark_output")"
  benchmark_backup_verified="$(jq -r '.disk_backed.backup_verified // false' "$benchmark_output")"
  benchmark_migration_count="$(jq -r '.disk_backed.migration_v5_to_v6_seed_papers // -1' "$benchmark_output")"
  benchmark_v7_warm_p95="$(jq -r '.v7_active_domain.warm_search_p95_ms // -1' "$benchmark_output")"
  benchmark_v7_cold_open_p95="$(jq -r '.v7_active_domain.cold_open_p95_ms // -1' "$benchmark_output")"
  benchmark_v7_single_mutation_p95="$(jq -r '.v7_active_domain.single_row_mutation_p95_ms // -1' "$benchmark_output")"
  benchmark_v7_backup_verified="$(jq -r '.v7_active_domain.backup_verified // false' "$benchmark_output")"
  benchmark_v7_authors="$(jq -r '.v7_active_domain.authors // -1' "$benchmark_output")"
  benchmark_v7_papers="$(jq -r '.v7_active_domain.papers // -1' "$benchmark_output")"
  benchmark_v7_links="$(jq -r '.v7_active_domain.links // -1' "$benchmark_output")"
  benchmark_v7_chunks="$(jq -r '.v7_active_domain.chunks // -1' "$benchmark_output")"
  if [[ "$benchmark_warm_p95" =~ '^[0-9]+$' && "$benchmark_warm_p95" -le 250 && \
        "$benchmark_cold_open_p95" =~ '^[0-9]+$' && "$benchmark_cold_open_p95" -le 5000 && \
        "$benchmark_single_mutation_p95" =~ '^[0-9]+$' && "$benchmark_single_mutation_p95" -le 100 && \
        "$benchmark_backup_verified" == true && "$benchmark_migration_count" -eq 20000 && \
        "$benchmark_v7_warm_p95" =~ '^[0-9]+$' && "$benchmark_v7_warm_p95" -le 250 && \
        "$benchmark_v7_cold_open_p95" =~ '^[0-9]+$' && "$benchmark_v7_cold_open_p95" -le 5000 && \
        "$benchmark_v7_single_mutation_p95" =~ '^[0-9]+$' && "$benchmark_v7_single_mutation_p95" -le 100 && \
        "$benchmark_v7_backup_verified" == true && "$benchmark_v7_authors" -eq 2000 && \
        "$benchmark_v7_papers" -eq 20000 && "$benchmark_v7_links" -eq 100000 && "$benchmark_v7_chunks" -eq 10000 ]]; then
    benchmark_within_target=1
  else
    failures+=1
    failure_entry swiftdata_large_store_threshold "$scratch/swiftpm_tests.log"
  fi
  # Publish only a complete, parseable benchmark and replace the project copy
  # atomically.  A failed run can never leave a partial root artifact or keep
  # a stale success merely because a previous file happened to exist.
  benchmark_stage="$project_root/.benchmark-v4-$run_id.json"
  cp "$benchmark_output" "$benchmark_stage"
  mv -f "$benchmark_stage" "$project_root/benchmark-v4.json"
else
  failures+=1
  failure_entry swiftdata_large_store "$scratch/swiftpm_tests.log"
fi
if [[ $swiftpm_tests -eq 1 ]] && rg -q "testPreOpenV5ToV6MigrationWritesVerifiedBackupAndIndependentJournal.*passed" "$scratch/swiftpm_tests.log" && \
   rg -q "testV7MaterializesLegacySnapshotOnceThenUsesDomainRecordsAsActiveTruth.*passed" "$scratch/swiftpm_tests.log" && \
   rg -q "testDiskBackedV6ToV7MaterializesWithVerifiedPreOpenBackupAndReopens.*passed" "$scratch/swiftpm_tests.log"; then
  migration_rollback=1
fi

run_gate swiftpm_release swift build -c release --scratch-path "$scratch/swift-release" -Xswiftc -warnings-as-errors
if [[ $? -eq 0 ]]; then swiftpm_release=1; else :; fi

common_xcode=(
  -project LatticeLens.xcodeproj
  -scheme LatticeLens
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$scratch/derived"
  CODE_SIGNING_ALLOWED=NO
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
  SWIFT_STRICT_CONCURRENCY=complete
)

# On this target macOS, unsigned UI-test runners are killed before they can
# establish the automation connection.  These arguments create only a local
# ad-hoc signature (identity `-`), not a Developer ID signature, notarized
# build, or distributable artifact.  Keep this separate from compile gates so
# the ledger can retain that boundary precisely.
ui_xcode=(
  -project LatticeLens.xcodeproj
  -scheme LatticeLens
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$scratch/derived"
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGN_IDENTITY=-
  DEVELOPMENT_TEAM=
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
  SWIFT_STRICT_CONCURRENCY=complete
)

xcode_timeout_seconds="${LATTICELENS_V4_XCODE_TIMEOUT_SECONDS:-600}"
if ! [[ "$xcode_timeout_seconds" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "LATTICELENS_V4_XCODE_TIMEOUT_SECONDS must be a positive integer"
  exit 2
fi

run_xcode_gate xcode_debug xcodebuild "${common_xcode[@]}" -configuration Debug build -quiet
if [[ $? -eq 0 ]]; then xcode_debug=1; else :; fi

unit_result="$scratch/xcode-unit.xcresult"
run_xcode_gate xcode_unit xcodebuild "${common_xcode[@]}" -configuration Debug -resultBundlePath "$unit_result" -only-testing:LatticeLensTests test -quiet
if [[ $? -eq 0 ]]; then xcode_unit=1; else :; fi

run_xcode_gate xcode_release xcodebuild "${common_xcode[@]}" -configuration Release build -quiet
if [[ $? -eq 0 ]]; then xcode_release=1; else :; fi

run_xcode_gate xcode_analyze xcodebuild "${common_xcode[@]}" -configuration Debug analyze -quiet
if [[ $? -eq 0 ]]; then xcode_analyze=1; else :; fi

build_result="$scratch/xcode-build-for-testing.xcresult"
run_xcode_gate xcode_build_for_testing xcodebuild "${ui_xcode[@]}" -resultBundlePath "$build_result" build-for-testing -quiet
if [[ $? -eq 0 ]]; then xcode_build_for_testing=1; ui_compiled=1; else :; fi

ui_timeout_seconds="${LATTICELENS_V4_UI_TIMEOUT_SECONDS:-900}"
ui_max_attempts="${LATTICELENS_V4_UI_MAX_ATTEMPTS:-3}"
ui_retry_delay_seconds="${LATTICELENS_V4_UI_RETRY_DELAY_SECONDS:-15}"
xcresult_finalization_seconds="${LATTICELENS_V4_XCRESULT_FINALIZATION_SECONDS:-600}"
xcresult_command_timeout_seconds="${LATTICELENS_V4_XCRESULT_COMMAND_TIMEOUT_SECONDS:-30}"
if ! [[ "$ui_max_attempts" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "LATTICELENS_V4_UI_MAX_ATTEMPTS must be a positive integer"
  exit 2
fi
if ! [[ "$ui_retry_delay_seconds" =~ '^[0-9]+$' ]]; then
  print -u2 "LATTICELENS_V4_UI_RETRY_DELAY_SECONDS must be a non-negative integer"
  exit 2
fi
if ! [[ "$xcresult_finalization_seconds" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "LATTICELENS_V4_XCRESULT_FINALIZATION_SECONDS must be a positive integer"
  exit 2
fi
if ! [[ "$xcresult_command_timeout_seconds" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "LATTICELENS_V4_XCRESULT_COMMAND_TIMEOUT_SECONDS must be a positive integer"
  exit 2
fi
if $skip_ui; then
  print "SKIP ui_runtime (--skip-ui)"
else
  if [[ $ui_compiled -eq 1 ]]; then
    # UI automation bootstrap is a host service.  An individual runner can
    # time out before the app launches, even though a fresh runner succeeds.
    # Retry only that host-owned bootstrap with independent logs/results; a
    # retry never treats a previous run's root evidence as current evidence.
    # Eighteen independent XCUIApplication launches can legitimately take
    # several minutes, so each attempt also retains a bounded command timeout.
    last_ui_log="$scratch/ui-runtime-1.log"
    typeset -i ui_attempt=1
    while (( ui_attempt <= ui_max_attempts && ui_runtime == 0 )); do
      attempt_result="$scratch/ui-attempt-$ui_attempt.xcresult"
      attempt_log="$scratch/ui-runtime-$ui_attempt.log"
      last_ui_log="$attempt_log"
      ui_attempts_executed="$ui_attempt"
      minimum_ui_total=0
      if run_bounded_xcode_command "$ui_timeout_seconds" xcodebuild "${ui_xcode[@]}" -resultBundlePath "$attempt_result" test-without-building -parallel-testing-enabled NO -only-testing:LatticeLensUITests >"$attempt_log" 2>&1; then
        ui_executed=1
        minimum_ui_total="$ui_business_cases_required"
      fi
      cleanup_task_owned_xcode_processes >>"$attempt_log" 2>&1

      # A successful command must finalize a result that covers every
      # declared XCUIApplication business case.  Waiting avoids sampling a
      # just-created bundle; root-level historical summaries are never used.
      if summary_json="$(read_xcresult_summary_after_finalization "$attempt_result" "$minimum_ui_total" "$xcresult_finalization_seconds")"; then
        ui_readable=1
        ui_total="$(print -r -- "$summary_json" | jq -r '.totalTestCount // 0')"
        ui_passed="$(print -r -- "$summary_json" | jq -r '.passedTests // 0')"
        ui_failed="$(print -r -- "$summary_json" | jq -r '.failedTests // 0')"
        ui_skipped="$(print -r -- "$summary_json" | jq -r '.skippedTests // 0')"
        # A compile-time-only or filtered result can never satisfy this gate.
        if [[ "$ui_total" -ge "$ui_business_cases_required" && "$ui_failed" -eq 0 && "$ui_passed" -eq "$ui_total" ]]; then
          ui_runtime=1
          ui_business_cases_passed="$ui_business_cases_required"
          ui_successful_attempt="$ui_attempt"
          ui_result="$attempt_result"
        fi
      fi
      if [[ $ui_runtime -eq 0 && $ui_attempt -lt $ui_max_attempts && $ui_retry_delay_seconds -gt 0 ]]; then
        print -u2 "RETRY ui_runtime after ${ui_retry_delay_seconds}s cooldown (attempt $((ui_attempt + 1)) of $ui_max_attempts)"
        /bin/sleep "$ui_retry_delay_seconds"
      fi
      (( ui_attempt += 1 ))
    done

    if [[ $ui_runtime -eq 1 ]]; then
      # Retain an app-level artifact only from the current successful attempt.
      ui_summary_file="$project_root/validation-v4-ui-summary.json"
      print -r -- "$summary_json" > "$ui_summary_file"
      ui_result_copy="$project_root/validation-v4-ui.xcresult"
      if [[ -e "$ui_result_copy" ]]; then
        /bin/rm -rf -- "$ui_result_copy"
      fi
      /usr/bin/ditto "$ui_result" "$ui_result_copy"
    else
      # The v4 acceptance contract makes this runtime gate mandatory. A
      # readable but incomplete/failed result is evidence of failure, never a
      # zero exit merely because compilation or a separate attempt succeeded.
      failures+=1
      ui_failure_recorded=1
      failure_entry ui_runtime "$last_ui_log"
      failure_entry ui_result_finalization "$scratch/xcresult-finalization.log"
    fi
  else
    print -u2 "BLOCK ui_runtime: build-for-testing did not complete"
    failures+=1
  fi
fi

source_hash="$(find Sources Tests Scripts -type f ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
benchmark_json='null'
[[ -s "$benchmark_output" ]] && benchmark_json="$(cat "$benchmark_output")"
unit_summary='null'
# `xcresulttool` succeeds only after the result bundle has been finalized.
# Capture its output separately so a transient or malformed bundle remains a
# visible `result_readable: false` state instead of producing invalid ledger
# JSON under `set -u` / `pipefail`.
unit_summary_value="$(read_xcresult_summary_after_finalization "$unit_result" 0 "$xcresult_finalization_seconds" 2>/dev/null || true)"
if [[ -n "$unit_summary_value" ]] && print -r -- "$unit_summary_value" | jq -e . >/dev/null 2>&1; then
  unit_summary="$unit_summary_value"
fi
ui_cases_json="$(rg -o 'func test[A-Za-z0-9_]+' Tests/LatticeLensUITests/LatticeLensUITests.swift | sed 's/^func //' | jq -Rsc 'split("\n") | map(select(length > 0))')"
failure_array="[$(print -r -- ${(j:,:)failure_json})]"

summary_path="$project_root/validation-v4.json"
cat > "$summary_path" <<EOF
{
  "schema_version": "latticelens-verify-v4",
  "run_id": "$run_id",
  "local_only": $local_only,
  "swiftpm_tests": {"passed": $([[ $swiftpm_tests -eq 1 ]] && print true || print false), "executed": $swiftpm_test_count, "skipped": $swiftpm_skipped, "failed": $swiftpm_failed},
  "swiftpm_release": $([[ $swiftpm_release -eq 1 ]] && print true || print false),
  "xcode_timeout_seconds": $xcode_timeout_seconds,
  "ui_retry_delay_seconds": $ui_retry_delay_seconds,
  "xcresult_finalization_seconds": $xcresult_finalization_seconds,
  "xcresult_command_timeout_seconds": $xcresult_command_timeout_seconds,
  "xcode_debug": $([[ $xcode_debug -eq 1 ]] && print true || print false),
  "xcode_unit_tests": {"passed": $([[ $xcode_unit -eq 1 ]] && print true || print false), "result_readable": $([[ "$unit_summary" != null ]] && print true || print false), "summary": $unit_summary},
  "xcode_release": $([[ $xcode_release -eq 1 ]] && print true || print false),
  "xcode_analyze": $([[ $xcode_analyze -eq 1 ]] && print true || print false),
  "xcode_build_for_testing": $([[ $xcode_build_for_testing -eq 1 ]] && print true || print false),
  "ui_runtime": {"compiled": $([[ $ui_compiled -eq 1 ]] && print true || print false), "executed": $([[ $ui_executed -eq 1 ]] && print true || print false), "readable_result": $([[ $ui_readable -eq 1 ]] && print true || print false), "feature_complete_gate": $([[ $ui_runtime -eq 1 ]] && print true || print false), "total": $ui_total, "passed": $ui_passed, "failed": $ui_failed, "skipped": $ui_skipped, "business_cases_required": $ui_business_cases_required, "business_cases_passed": $ui_business_cases_passed, "business_cases": $ui_cases_json, "result_bundle": "validation-v4-ui.xcresult"},
  "swiftdata_large_store": {"completed": $([[ $benchmark -eq 1 ]] && print true || print false), "within_targets": $([[ $benchmark_within_target -eq 1 ]] && print true || print false), "within_warm_search_target": $([[ $benchmark_warm_p95 -ge 0 && $benchmark_warm_p95 -le 250 ]] && print true || print false), "warm_search_p95_target_ms": 250, "warm_search_p95_ms": $benchmark_warm_p95, "cold_open_p95_target_ms": 5000, "cold_open_p95_ms": $benchmark_cold_open_p95, "single_row_mutation_p95_target_ms": 100, "single_row_mutation_p95_ms": $benchmark_single_mutation_p95, "backup_verified": $benchmark_backup_verified, "migration_seed_papers": $benchmark_migration_count, "v7_active_domain": {"store_is_current_active_truth": true, "within_targets": $([[ $benchmark_v7_warm_p95 -ge 0 && $benchmark_v7_warm_p95 -le 250 && $benchmark_v7_cold_open_p95 -ge 0 && $benchmark_v7_cold_open_p95 -le 5000 && $benchmark_v7_single_mutation_p95 -ge 0 && $benchmark_v7_single_mutation_p95 -le 100 && "$benchmark_v7_backup_verified" == true && $benchmark_v7_authors -eq 2000 && $benchmark_v7_papers -eq 20000 && $benchmark_v7_links -eq 100000 && $benchmark_v7_chunks -eq 10000 ]] && print true || print false), "warm_search_p95_target_ms": 250, "warm_search_p95_ms": $benchmark_v7_warm_p95, "cold_open_p95_target_ms": 5000, "cold_open_p95_ms": $benchmark_v7_cold_open_p95, "single_row_mutation_p95_target_ms": 100, "single_row_mutation_p95_ms": $benchmark_v7_single_mutation_p95, "backup_verified": $benchmark_v7_backup_verified, "authors": $benchmark_v7_authors, "papers": $benchmark_v7_papers, "links": $benchmark_v7_links, "chunks": $benchmark_v7_chunks}, "result": $benchmark_json},
  "migration_rollback": {"contract_tests_passed": $([[ $migration_rollback -eq 1 ]] && print true || print false), "tests": ["testPreOpenV5ToV6MigrationWritesVerifiedBackupAndIndependentJournal", "testV7MaterializesLegacySnapshotOnceThenUsesDomainRecordsAsActiveTruth", "testDiskBackedV6ToV7MaterializesWithVerifiedPreOpenBackupAndReopens"]},
  "search_index": "contract_and_swiftdata_projection",
  "bundle_restore": "contract_tests_passed",
  "live_inspire": "not_run",
  "live_llm": "not_required",
  "cloudkit_live": "out_of_scope",
  "developer_id_notarization": "not_run",
  "artifact_hash": "$source_hash",
  "failures": $failures,
  "failure_evidence": $failure_array
}
EOF

print "$(cat "$summary_path")"
exit "$failures"
