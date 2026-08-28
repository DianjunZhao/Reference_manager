#!/bin/zsh
# Optional credential-free, read-only INSPIRE shape smoke.  The existing v3
# implementation already bounds retained bodies and performs no POST; this
# wrapper gives v4 a stable entry point without changing product state.
set -u
set -o pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
print "{\"schema_version\":\"latticelens-live-smoke-v4\",\"credential_free\":true,\"read_only\":true,\"delegated_script\":\"Scripts/live_smoke_v3.sh\"}"
zsh "$project_root/Scripts/live_smoke_v3.sh"
smoke_exit=$?
exit "$smoke_exit"
