#!/bin/zsh
# Local, credential-free verifier for the v2 checkout.  It deliberately does
# not run live INSPIRE/LLM, a UI-test session, signing, or notarization.
set -u
set -o pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$project_root/.codex-task-tmp-v2-verify"

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
typeset -i swift_test=1 swift_release=1 xcode_debug=1 xcode_unit=1 xcode_release=1 xcode_analyze=1

run_gate() {
  local name="$1"
  shift
  if "$@"; then
    print "PASS $name"
    return 0
  fi
  print -u2 "FAIL $name"
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

print "{\"schema_version\":\"latticelens-verify-v2\",\"local_only\":true,\"swiftpm_test\":$((1-swift_test)),\"swiftpm_release\":$((1-swift_release)),\"xcode_debug\":$((1-xcode_debug)),\"xcode_unit\":$((1-xcode_unit)),\"xcode_release\":$((1-xcode_release)),\"xcode_analyze\":$((1-xcode_analyze)),\"ui_runtime\":false,\"live_inspire\":false,\"live_llm\":false,\"failures\":$failures}"
exit "$failures"
