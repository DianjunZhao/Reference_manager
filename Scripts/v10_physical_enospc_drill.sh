#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
ROOT="$(pwd -P)"

SCRATCH="$(mktemp -d "$ROOT/.codex-task-tmp-g02-enospc.XXXXXXXX")"

cleanup() {
  if [[ -n "$SCRATCH" && -d "$SCRATCH" ]]; then
    case "$SCRATCH" in
      "$ROOT"/.codex-task-tmp-g02-enospc.*) /bin/rm -r "$SCRATCH" ;;
      *) print -u2 -- "Refusing to remove non-task scratch path: $SCRATCH"; return 1 ;;
    esac
  fi
}
trap cleanup EXIT

mkdir -p "$SCRATCH/home" "$SCRATCH/tmp" "$SCRATCH/test-stores"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
LOG_PATH="evidence/G02-PhysicalDiskExhaustion-${RUN_ID}.log"
if [[ -e "$LOG_PATH" ]]; then
  print -u2 -- "Refusing to overwrite existing evidence: $LOG_PATH"
  exit 2
fi

print -r -- "G02 physical ENOSPC drill: disposable HFS+ sparse image only" | tee "$LOG_PATH"
for INPUT_PATH in \
  Sources/LatticeLens/Core/Persistence/V4NormalizedStore.swift \
  Tests/LatticeLensTests/V4LocalTests.swift \
  Scripts/v10_physical_enospc_drill.sh; do
  INPUT_SHA256="$(/usr/bin/shasum -a 256 "$INPUT_PATH" | /usr/bin/awk '{print $1}')"
  print -r -- "G02_SOURCE_SHA256 $INPUT_PATH $INPUT_SHA256" | tee -a "$LOG_PATH"
done

set +e
env \
  HOME="$SCRATCH/home" \
  TMPDIR="$SCRATCH/tmp" \
  LATTICELENS_TEST_STORE_ROOT="$SCRATCH/test-stores" \
  LATTICELENS_REQUIRE_PROJECT_LOCAL_TEST_ROOTS=1 \
  LATTICELENS_V10_PHYSICAL_ENOSPC_DRILL=1 \
  swift test --scratch-path "$SCRATCH/swiftpm" --jobs 2 \
    --filter V4LocalTests/testV10MigrationPhysicalDiskExhaustionOnDisposableImage \
    2>&1 | tee -a "$LOG_PATH"
TEST_STATUS=${pipestatus[1]}
set -e
print -r -- "TEST_STATUS=$TEST_STATUS" | tee -a "$LOG_PATH"
print -r -- "LOG_PATH=$LOG_PATH"
print -r -- "LOG_SHA256=$(/usr/bin/shasum -a 256 "$LOG_PATH" | /usr/bin/awk '{print $1}')"
exit "$TEST_STATUS"
