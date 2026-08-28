#!/bin/zsh
# Credential-free v3 local verifier.  It runs current source/tests and keeps
# every scratch/result artifact inside one project-local directory.  Live
# INSPIRE, LLM, Keychain, CloudKit, signing and notarization are intentionally
# reported as false/blocked and are never inferred from local success.
set -u
set -o pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$project_root/.codex-task-tmp-v3-verify-$$"
if [[ -e "$scratch" ]]; then
  print -u2 "Refusing to reuse existing scratch path: $scratch"
  exit 2
fi

cleanup() {
  [[ -d "$scratch" ]] || return 0
  find "$scratch" -depth -type f -exec /bin/unlink {} ';'
  find "$scratch" -depth -type l -exec /bin/unlink {} ';'
  find "$scratch" -depth -type d -exec /bin/rmdir {} '+' 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mkdir -p "$scratch/persistence"
export LATTICELENS_TEST_STORE_ROOT="$scratch/persistence"
cd "$project_root"

typeset -i failures=0
typeset -i swift_test=1 swift_release=1 xcode_debug=1 xcode_unit=1 xcode_release=1 xcode_analyze=1 benchmark=1 ui_runtime=0

run_gate() {
  local name="$1"; shift
  if "$@" >"$scratch/$name.log" 2>&1; then
    print "PASS $name"
    return 0
  fi
  print -u2 "FAIL $name (see $scratch/$name.log)"
  failures+=1
  return 1
}

run_gate swiftpm_test swift test --scratch-path "$scratch/swift-test" && swift_test=0 || true
run_gate swiftpm_release swift build -c release --scratch-path "$scratch/swift-release" -Xswiftc -warnings-as-errors && swift_release=0 || true

common_xcode=(
  -project LatticeLens.xcodeproj
  -scheme LatticeLens
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$scratch/derived-data"
  CODE_SIGNING_ALLOWED=NO
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
  SWIFT_STRICT_CONCURRENCY=complete
)
run_gate xcode_debug xcodebuild "${common_xcode[@]}" -configuration Debug build -quiet && xcode_debug=0 || true
run_gate xcode_unit xcodebuild "${common_xcode[@]}" -configuration Debug -only-testing:LatticeLensTests test -quiet && xcode_unit=0 || true
run_gate xcode_release xcodebuild "${common_xcode[@]}" -configuration Release build -quiet && xcode_release=0 || true
run_gate xcode_analyze xcodebuild "${common_xcode[@]}" -configuration Debug analyze -quiet && xcode_analyze=0 || true
run_gate large_library_benchmark python3 Scripts/benchmark_v3.py --output "$scratch/benchmark-v3.json" --repeats 5 && benchmark=0 || true

test_count="$(sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p' "$scratch/swiftpm_test.log" 2>/dev/null | tail -1)"
skip_count="$(sed -nE 's/.*with ([0-9]+) tests? skipped.*/\1/p' "$scratch/swiftpm_test.log" 2>/dev/null | tail -1)"
[[ -n "$test_count" ]] || test_count=0
[[ -n "$skip_count" ]] || skip_count=0
source_hash="$(find Sources Tests Scripts -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
schema_version="$(plutil -extract v3SchemaVersion raw -o - validation-v3.json 2>/dev/null || print 3)"

benchmark_status=false; [[ $benchmark -eq 0 ]] && benchmark_status=true
print "{\"schema_version\":\"latticelens-verify-v3\",\"v3_schema_version\":$schema_version,\"local_only\":true,\"swiftpm_test\":$((1-swift_test)),\"test_count\":$test_count,\"skipped_count\":$skip_count,\"swiftpm_release\":$((1-swift_release)),\"xcode_debug\":$((1-xcode_debug)),\"xcode_unit\":$((1-xcode_unit)),\"xcode_release\":$((1-xcode_release)),\"xcode_analyze\":$((1-xcode_analyze)),\"large_library_benchmark\":$benchmark_status,\"ui_runtime\":false,\"live_inspire\":false,\"live_llm\":false,\"cloudkit_live\":false,\"artifact_hash\":\"$source_hash\",\"failures\":$failures}"
exit "$failures"
