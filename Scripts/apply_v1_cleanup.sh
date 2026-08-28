#!/bin/zsh
# Apply an explicitly user-approved cleanup manifest. All targets are
# independently revalidated before deletion. Only project-root scratch and
# fixture directories are eligible.
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

usage() {
  print -u2 'usage: zsh Scripts/apply_v1_cleanup.sh --approved-manifest <project-local-json> --receipt <new-project-local-json>'
  exit 64
}

[[ $# -eq 4 && "$1" == "--approved-manifest" && "$3" == "--receipt" ]] || usage
manifest="${2:A}"
receipt="${4:A}"
[[ "$manifest" == "$root"/* && -f "$manifest" && ! -L "$manifest" ]] || {
  print -u2 'approved manifest must be a regular project-local file'
  exit 65
}
[[ "$receipt" == "$root"/* && ! -e "$receipt" && ! -L "$receipt" ]] || {
  print -u2 'receipt must be a new project-local non-symlink path'
  exit 65
}
jq -e '
  .schema_version == "latticelens-cleanup-v1.0" and .mode == "approved_apply" and
  (.approved_by | type == "string" and length > 0) and
  (.approved_at_utc | type == "string" and length > 0) and
  (.allowed_relative_paths | type == "array" and all(type == "string" and length > 0 and (startswith("/") | not) and (contains("..") | not) and (contains("/") | not)))
' "$manifest" >/dev/null || {
  print -u2 'approved manifest has an invalid schema, mode, approval identity, or path list'
  exit 65
}

typeset -a approved_paths existing_paths absent_paths
approved_paths=("${(@f)$(jq -r '.allowed_relative_paths[]' "$manifest")}")
(( ${#approved_paths[@]} > 0 )) || {
  print -u2 'approved manifest contains no cleanup targets'
  exit 65
}

for relative_entry in "${approved_paths[@]}"; do
  case "$relative_entry" in
    .codex-task-tmp-*|LatticeLens-UIFixture-*) ;;
    *) print -u2 "refusing non-ephemeral cleanup target: $relative_entry"; exit 65 ;;
  esac
  candidate="$root/$relative_entry"
  if [[ ! -e "$candidate" ]]; then
    absent_paths+=("$relative_entry")
    continue
  fi
  [[ -d "$candidate" && ! -L "$candidate" ]] || {
    print -u2 "refusing non-directory or symlink cleanup target: $relative_entry"
    exit 65
  }
  canonical_path="${candidate:A}"
  [[ "$canonical_path" == "$root"/* ]] || {
    print -u2 "refusing project-root escape: $relative_entry"
    exit 65
  }
  (( $+commands[lsof] )) || {
    print -u2 'lsof is required to apply cleanup safely'
    exit 69
  }
  ! lsof +D "$candidate" >/dev/null 2>&1 || {
    print -u2 "refusing in-use cleanup target: $relative_entry"
    exit 65
  }
  existing_paths+=("$relative_entry")
done

typeset -a deleted_paths
typeset -i deleted_bytes=0
for relative_entry in "${existing_paths[@]}"; do
  candidate="$root/$relative_entry"
  deleted_bytes=$(( deleted_bytes + $(du -sk "$candidate" | awk '{print $1}') * 1024 ))
  find "$candidate" -depth -delete
  [[ ! -e "$candidate" ]] || {
    print -u2 "cleanup target remains after deletion: $relative_entry"
    exit 1
  }
  deleted_paths+=("$relative_entry")
done

deleted_json="$(jq -n --args '$ARGS.positional' -- "${deleted_paths[@]}")"
absent_json="$(jq -n --args '$ARGS.positional' -- "${absent_paths[@]}")"
jq -n \
  --arg applied_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg manifest_sha256 "$(shasum -a 256 "$manifest" | awk '{print $1}')" \
  --argjson deleted "$deleted_json" \
  --argjson already_absent "$absent_json" \
  --argjson deleted_bytes "$deleted_bytes" \
  '{schema_version:"latticelens-cleanup-apply-receipt-v1.0",result:"applied",appliedAtUTC:$applied_at,approvedManifestSHA256:$manifest_sha256,deletedRelativePaths:$deleted,alreadyAbsentRelativePaths:$already_absent,deletedBytes:$deleted_bytes}' \
  > "$receipt"
print -- "$receipt"
