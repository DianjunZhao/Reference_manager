#!/bin/zsh
# Run the one authorized real V7 -> V8 core -> V9 final-search migration,
# backup, recovery and search-index verification drill.
# The source is read-only by contract; all new artifacts are written below the
# separately named, empty disposable output root supplied by the user.
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
source_path=''
output_root=''
source_origin=''
while (( $# > 0 )); do
  case "$1" in
    --source) (( $# >= 2 )) || { print -u2 '--source needs an absolute .store path'; exit 64; }; source_path="$2"; shift 2 ;;
    --output-root) (( $# >= 2 )) || { print -u2 '--output-root needs an absolute empty directory'; exit 64; }; output_root="$2"; shift 2 ;;
    --source-origin) (( $# >= 2 )) || { print -u2 '--source-origin needs synthetic_v7_benchmark or user_provided_disposable_copy'; exit 64; }; source_origin="$2"; shift 2 ;;
    *) print -u2 'usage: zsh Scripts/migration_v7_disposable_drill.sh --source /absolute/disposable-v7.store --output-root /absolute/empty-disposable-output --source-origin synthetic_v7_benchmark|user_provided_disposable_copy'; exit 64 ;;
  esac
done
[[ -n "$source_path" && -n "$output_root" && -n "$source_origin" ]] || { print -u2 '--source, --output-root, and --source-origin are required'; exit 64; }
case "$source_origin" in
  synthetic_v7_benchmark|user_provided_disposable_copy) ;;
  *) print -u2 '--source-origin must be synthetic_v7_benchmark or user_provided_disposable_copy'; exit 65 ;;
esac
[[ "$source_path" == /* && "$output_root" == /* ]] || { print -u2 'both paths must be absolute and explicitly user-selected'; exit 65; }
source_path="${source_path:A}"
output_root="${output_root:A}"
[[ -f "$source_path" && "$source_path" == *.store && ! -L "$source_path" ]] || {
  print -u2 'source must be a non-symlink, disposable V7 main .store file'
  exit 65
}
[[ -d "$output_root" && ! -L "$output_root" ]] || { print -u2 'output root must be an existing non-symlink directory'; exit 65; }
[[ -z "$(find "$output_root" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
  print -u2 'output root must be empty; the drill will never merge into an existing directory'
  exit 65
}
case "$source_path" in "$output_root"/*) print -u2 'source cannot be inside the drill output root'; exit 65 ;; esac
case "$output_root" in "${source_path:h}"/*) print -u2 'output root cannot contain the source family'; exit 65 ;; esac
for member in "$source_path" "$source_path-wal" "$source_path-shm"; do
  [[ ! -e "$member" || ! -L "$member" ]] || { print -u2 "refusing symlink store-family member: $member"; exit 65; }
done

# A live writer invalidates the stable-copy premise. lsof returns nonzero when
# no process has the store open; that is the only accepted state for this drill.
if lsof "$source_path" "${source_path}-wal" "${source_path}-shm" 2>/dev/null | tail -n +2 | rg -q .; then
  print -u2 'source V7 family is currently open by another process; quit the app/writer before retrying'
  exit 66
fi

print "Running authorized disposable V7-to-final-V9 migration drill (source_origin=$source_origin). Source is never the active library and will be byte-compared after migration."
LATTICELENS_V5_DISPOSABLE_V7_STORE="$source_path" \
LATTICELENS_V5_DISPOSABLE_DRILL_ROOT="$output_root" \
LATTICELENS_V5_DISPOSABLE_SOURCE_ORIGIN="$source_origin" \
  swift test --filter V5FinalTests/testAuthorizedDisposableV7MigrationDrill
result_dir="$(find "$output_root" -mindepth 1 -maxdepth 1 -type d -name 'LatticeLens-V9-Disposable-Drill-*' -print -quit)"
[[ -n "$result_dir" && -f "$result_dir/migration-v7-disposable-drill.json" ]] || {
  print -u2 'migration test returned success but did not produce its sanitized evidence record'
  exit 1
}
print "PASS authorized disposable drill; retained sanitized evidence: $result_dir/migration-v7-disposable-drill.json"
