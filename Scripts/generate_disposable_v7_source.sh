#!/bin/zsh
# Generate the one explicitly authorized, non-empty V7 benchmark family for
# a disposable migration drill.  It never reads Application Support, Keychain,
# PDFs, or a user library.  The resulting source is intentionally labelled
# synthetic and must not be presented as a copy of research data.
set -euo pipefail

root="${0:A:h:h}"
source_root="$root/DisposableMigrationV7Source"
source_path="$source_root/synthetic-v7-benchmark-disposable.store"

[[ -d "$source_root" && ! -L "$source_root" ]] || {
  print -u2 'DisposableMigrationV7Source must be an existing non-symlink directory'
  exit 65
}
[[ -z "$(find "$source_root" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
  print -u2 'DisposableMigrationV7Source must be empty; refusing to replace an existing source family'
  exit 65
}

print 'Generating a non-empty synthetic V7 benchmark family; no user library is read.'
LATTICELENS_RUN_V4_BENCHMARK=1 \
LATTICELENS_V5_SYNTHETIC_V7_SOURCE_OUTPUT="$source_path" \
  swift test --filter V4BenchmarkTests/testActualSwiftDataLargeStoreBenchmark

[[ -f "$source_path" && ! -L "$source_path" ]] || {
  print -u2 'benchmark completed without producing the requested V7 main .store'
  exit 1
}
if lsof "$source_path" "${source_path}-wal" "${source_path}-shm" 2>/dev/null | tail -n +2 | rg -q .; then
  print -u2 'generated V7 family is unexpectedly still open; refusing to declare it closed'
  exit 1
fi

print "PASS generated closed synthetic source: $source_path"
