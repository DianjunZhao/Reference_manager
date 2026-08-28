#!/bin/zsh
# Reproducible local v1 gate.  It deliberately uses only fixture data and does
# not call a live LLM provider.  All transient products stay below the project.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$project_root/.codex-task-tmp-v1-verify"

if [[ -e "$scratch" ]]; then
  print -u2 "Refusing to reuse existing scratch path: $scratch"
  exit 2
fi

cleanup() {
  [[ -d "$scratch" ]] || return 0
  find "$scratch" -depth -type f -exec /bin/unlink {} \;
  find "$scratch" -depth -type l -exec /bin/unlink {} \;
  find "$scratch" -depth -type d -exec /bin/rmdir {} \; 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mkdir -p "$scratch/persistence"
export LATTICELENS_TEST_STORE_ROOT="$scratch/persistence"

cd "$project_root"

swift test --scratch-path "$scratch/swift-package"

common_xcode=(
  -project LatticeLens.xcodeproj
  -scheme LatticeLens
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$scratch/derived-data"
  CODE_SIGNING_ALLOWED=NO
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
  SWIFT_STRICT_CONCURRENCY=complete
)

xcodebuild "${common_xcode[@]}" -configuration Debug build -quiet
xcodebuild "${common_xcode[@]}" -configuration Debug -only-testing:LatticeLensTests test -quiet
xcodebuild "${common_xcode[@]}" -configuration Release build -quiet
xcodebuild "${common_xcode[@]}" -configuration Debug analyze -quiet
archive_xcode=(
  -project LatticeLens.xcodeproj
  -scheme LatticeLens
  -destination 'generic/platform=macOS'
  -derivedDataPath "$scratch/derived-data"
  CODE_SIGNING_ALLOWED=NO
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
  SWIFT_STRICT_CONCURRENCY=complete
)
xcodebuild "${archive_xcode[@]}" -configuration Release \
  -archivePath "$scratch/LatticeLens.xcarchive" archive -quiet

print "v1 local gates passed (fixture/build/test/analyze/unsigned archive)."
