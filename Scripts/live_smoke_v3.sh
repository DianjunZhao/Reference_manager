#!/bin/zsh
# Credential-free, read-only INSPIRE shape smoke for v3.
# It never sends an Authorization header, never writes to the service, and
# only records response classes/types; raw JSON remains in task-local scratch.
set -u
set -o pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$project_root/.codex-task-tmp-v3-live-smoke-$$"
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
mkdir -p "$scratch"

typeset -i failures=0
typeset -a records

get_json() {
  local name="$1" url="$2" body="$scratch/$1.json" http_status
  http_status="$(/usr/bin/curl --silent --show-error --location --retry 2 --retry-all-errors --retry-delay 1 --max-time 30 --connect-timeout 10 \
    -H 'Accept: application/json' -o "$body" -w '%{http_code}' "$url" 2>"$scratch/$1.curl.log" || true)"
  [[ -n "$http_status" ]] || http_status=000
  if [[ "$http_status" != 2[0-9][0-9] ]]; then
    print -u2 "FAIL $name http_status=$http_status"
    failures+=1
    records+=("{\"name\":\"$name\",\"http_status\":$http_status,\"json\":false}")
    return 1
  fi
  if ! /usr/bin/jq -e type "$body" >/dev/null 2>&1; then
    print -u2 "FAIL $name malformed_json"
    failures+=1
    records+=("{\"name\":\"$name\",\"http_status\":$http_status,\"json\":false}")
    return 1
  fi
  records+=("{\"name\":\"$name\",\"http_status\":$http_status,\"json\":true}")
  print "PASS $name http_status=$http_status"
  return 0
}

get_http() {
  local name="$1" url="$2" method="$3" body="$scratch/$1.body" http_status
  if [[ "$method" == "HEAD" ]]; then
    http_status="$(/usr/bin/curl --silent --show-error --location --retry 2 --retry-all-errors --retry-delay 1 --head --max-time 30 --connect-timeout 10 -o "$body" -w '%{http_code}' "$url" 2>"$scratch/$1.curl.log" || true)"
  else
    http_status="$(/usr/bin/curl --silent --show-error --location --retry 2 --retry-all-errors --retry-delay 1 --max-time 30 --connect-timeout 10 --range 0-4095 -o "$body" -w '%{http_code}' "$url" 2>"$scratch/$1.curl.log" || true)"
  fi
  [[ -n "$http_status" ]] || http_status=000
  if [[ "$http_status" != 2[0-9][0-9] ]]; then
    print -u2 "FAIL $name http_status=$http_status"; failures+=1
    records+=("{\"name\":\"$name\",\"http_status\":$http_status,\"method\":\"$method\"}"); return 1
  fi
  records+=("{\"name\":\"$name\",\"http_status\":$http_status,\"method\":\"$method\",\"bounded\":true}")
  print "PASS $name $method http_status=$http_status"; return 0
}

get_json self_author 'https://inspirehep.net/api/authors/2010363' || true
if [[ -f "$scratch/self_author.json" ]]; then
  /usr/bin/jq -e '.id == "2010363" and (.metadata.arxiv_categories // [] | index("hep-lat")) != null' \
    "$scratch/self_author.json" >/dev/null 2>&1 || { print -u2 "FAIL self_author semantic_shape"; failures+=1; }
fi

get_json author_search 'https://inspirehep.net/api/authors?q=arxiv_categories%3Ahep-lat&size=1' || true
if [[ -f "$scratch/author_search.json" ]]; then
  /usr/bin/jq -e '(.hits | type == "object") and (.hits.hits | type == "array") and (((.hits.total // 0) | if type == "object" then (.value // 0) else . end) >= 0)' \
    "$scratch/author_search.json" >/dev/null 2>&1 || { print -u2 "FAIL author_search semantic_shape"; failures+=1; }
  next_url="$(/usr/bin/jq -r '.links.next // empty' "$scratch/author_search.json" 2>/dev/null || true)"
  if [[ -n "$next_url" && "$next_url" != https://inspirehep.net/* ]]; then
    print -u2 "FAIL author_search untrusted_next_origin"
    failures+=1
  fi
fi

get_json literature_search 'https://inspirehep.net/api/literature?q=authors.recid%3A2010363&size=1' || true
if [[ -f "$scratch/literature_search.json" ]]; then
  /usr/bin/jq -e '(.hits | type == "object") and (.hits.hits | type == "array") and (((.hits.total // 0) | if type == "object" then (.value // 0) else . end) >= 0)' \
    "$scratch/literature_search.json" >/dev/null 2>&1 || { print -u2 "FAIL literature_search semantic_shape"; failures+=1; }
fi

get_json candidate 'https://inspirehep.net/api/literature?q=arxiv_categories%3Ahep-lat&size=1&sort=mostrecent' || true
get_json qualified_h_summary 'https://inspirehep.net/api/literature/facets?q=authors.recid%3A2010363&facet_name=citation-summary' || true
get_json self_literature_page 'https://inspirehep.net/api/literature?q=authors.recid%3A2010363&size=1&page=1&sort=mostrecent' || true

# BibTeX is a read-only representation endpoint; do not retain its body.
bibtex_id="$(/usr/bin/jq -r '.hits.hits[0].id // empty' "$scratch/literature_search.json" 2>/dev/null || true)"
if [[ -n "$bibtex_id" ]]; then
  get_http "bibtex_$bibtex_id" "https://inspirehep.net/api/literature/$bibtex_id?format=bibtex" GET || true
  document_url="$(/usr/bin/jq -r '.hits.hits[0].metadata.documents[0].url // empty' "$scratch/literature_search.json" 2>/dev/null || true)"
  figure_url="$(/usr/bin/jq -r '.hits.hits[0].metadata.figures[0].url // empty' "$scratch/literature_search.json" 2>/dev/null || true)"
  [[ -n "$document_url" ]] && get_http "pdf_policy_$bibtex_id" "$document_url" HEAD || true
  [[ -n "$figure_url" ]] && get_http "figure_policy_$bibtex_id" "$figure_url" HEAD || true
fi

records_json="[$(print -n -- ${(j:,:)records})]"
print "{\"schema_version\":\"latticelens-live-smoke-v3\",\"credential_free\":true,\"read_only\":true,\"failures\":$failures,\"endpoints\":$records_json}"
exit "$failures"
