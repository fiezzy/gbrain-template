#!/usr/bin/env bash
# Smoke tests. Run after bootstrap + refresh, and any time search "feels wrong".
#
#   ./scripts/verify.sh
#
# Every check here exists because the corresponding failure is SILENT: the
# brain answers, it just answers with less than it should. A half-loaded
# reranker returns "No results". An untrusted stdio transport returns [] for
# cross-source queries. A sync run with the wrong strategy imports the three
# README files and calls it a day. None of that raises an error anywhere.
#
# Exit code 0 = everything passed. 1 = at least one hard failure.

set -uo pipefail   # deliberately NOT -e: a failing check must not abort the run
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/mcp-probe.sh
source "$HERE/lib/mcp-probe.sh"
load_conf

PASS=0; FAIL=0; WARN=0
pass()  { PASS=$((PASS+1)); printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
fail()  { FAIL=$((FAIL+1)); printf '%s  ✗%s %s\n' "$C_RED" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; }
soft()  { WARN=$((WARN+1)); printf '%s  ~%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; }

PROBE_TOKEN="GBRAINTEMPLATEPROBE7F3AD2"

echo
printf '%s  %s — verification%s\n' "$C_BOLD" "${BRAIN_NAME:-$BRAIN_ID}" "$C_RESET"
echo

# ------------------------------------------------------------ toolchain ----

log "Toolchain"

installed="$(gbrain --version 2>/dev/null | awk '{print $2}')"
if [[ -z "$installed" ]]; then
  fail "gbrain not on PATH"
elif [[ "$installed" == "${GBRAIN_PIN#v}" ]]; then
  pass "gbrain $installed (matches pin)"
else
  soft "gbrain $installed, brain.conf pins ${GBRAIN_PIN#v}" \
       "gbrain installs globally; another brain on this machine may have moved it."
fi

# -------------------------------------------------------------- storage ----

log "Storage"

if pg_running; then
  pass "postgres reachable on :$PG_PORT"
else
  fail "postgres not reachable on :$PG_PORT" "try: scripts/serve.sh, or check $PGDATA/server.log"
fi

if [[ -f "$GBRAIN_CONFIG_DIR/config.json" ]]; then
  pass "brain config at $GBRAIN_CONFIG_DIR"
  cfg_dims=$(grep -o '"embedding_dimensions"[[:space:]]*:[[:space:]]*[0-9]*' \
             "$GBRAIN_CONFIG_DIR/config.json" | grep -o '[0-9]*$' || true)
  if [[ -z "$cfg_dims" ]]; then
    soft "could not read embedding_dimensions from config.json"
  elif [[ "$cfg_dims" == "$EMBED_DIMS" ]]; then
    pass "embedding width ${cfg_dims}d matches brain.conf"
  else
    fail "brain is ${cfg_dims}d but brain.conf says ${EMBED_DIMS}d" \
         "One of them is wrong. Changing width needs: gbrain retrieval-upgrade --to <model> --reindex"
  fi
else
  fail "brain not initialized" "run scripts/bootstrap.sh"
fi

# --------------------------------------------------------------- corpus ----

log "Corpus"

if pg_running; then
  pages=$(psql_brain -tAc "select count(*) from pages" 2>/dev/null || echo 0)
  chunks=$(psql_brain -tAc "select count(*) from content_chunks" 2>/dev/null || echo 0)
  unembedded=$(psql_brain -tAc "select count(*) from content_chunks where embedding is null" 2>/dev/null || echo '?')

  if (( pages > 0 )); then
    pass "$pages pages / $chunks chunks"
  else
    fail "no pages indexed" "run scripts/refresh.sh"
  fi

  if [[ "$unembedded" == "0" ]]; then
    pass "every chunk is embedded"
  elif [[ "$unembedded" == "?" ]]; then
    soft "could not count un-embedded chunks"
  else
    fail "$unembedded chunks have no embedding" \
         "They are invisible to vector search. Run scripts/refresh.sh; if they persist, find the offending file and sparse-exclude it."
  fi

  # Vector index. Above pgvector's 2000-dim ceiling HNSW cannot be built at
  # all, and exact scan is the correct (if slower) configuration — report it
  # honestly rather than calling it a failure.
  has_hnsw=$(psql_brain -tAc \
    "select count(*) from pg_indexes where tablename='content_chunks' and indexdef ilike '%hnsw%' and indexdef ilike '%(embedding %'" \
    2>/dev/null || echo 0)
  if (( EMBED_DIMS > 2000 )); then
    soft "no HNSW index — ${EMBED_DIMS}d exceeds pgvector's 2000-dim ceiling" \
         "Vector search is an exact scan: correct, but O(n). Fine solo; switch to a <=2000d model before serving a team."
  elif (( has_hnsw > 0 )); then
    pass "HNSW index present on the embedding column"
  else
    soft "no HNSW index although ${EMBED_DIMS}d allows one" "gbrain doctor should propose the fix"
  fi
fi

# -------------------------------------------------------------- sources ----

log "Sources"

registered="$(gbrain sources list 2>/dev/null || true)"
missing_sources=()
while IFS=$'\t' read -r id url branch strategy visibility; do
  grep -qE "(^|[^a-z0-9-])$id([^a-z0-9-]|$)" <<<"$registered" || missing_sources+=("$id")
done < <(manifest_rows)
grep -qE "(^|[^a-z0-9-])inbox([^a-z0-9-]|$)" <<<"$registered" || missing_sources+=("inbox")

if (( ${#missing_sources[@]} == 0 )); then
  pass "every manifest source is registered (+ inbox)"
else
  fail "not registered: ${missing_sources[*]}" "run scripts/bootstrap.sh"
fi

wrong_branch=()
while IFS=$'\t' read -r id url branch strategy visibility; do
  clone="$CLONES_DIR/$id"
  [[ -d "$clone/.git" ]] || { wrong_branch+=("$id:missing"); continue; }
  actual="$(git -C "$clone" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  [[ "$actual" == "$branch" ]] || wrong_branch+=("$id:$actual≠$branch")
done < <(manifest_rows)

if (( ${#wrong_branch[@]} == 0 )); then
  pass "every clone is on its manifest branch"
else
  fail "branch mismatch: ${wrong_branch[*]}" "run scripts/bootstrap.sh"
fi

# --------------------------------------------------------- exclusions ----

log "Exclusions"

leaked=()
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    [[ -e "$CLONES_DIR/$id/$path" ]] && leaked+=("$id/$path")
  done < <(sparse_paths_for "$id")
done < <(sparse_ids)

if (( ${#leaked[@]} == 0 )); then
  pass "no excluded path is present on disk"
else
  fail "sparse-checkout did not remove: ${leaked[*]}" "run scripts/bootstrap.sh"
fi

# Secrets should never have reached the index. Code strategy skips dotfiles,
# but a committed config with a telling name would not be skipped.
if pg_running; then
  secret_pages=$(psql_brain -tAc "
    select count(*) from pages
    where coalesce(frontmatter->>'file', source_path, slug) ~* '(^|/)\.env|secrets?\.(ya?ml|json|ts|js|py)$|credentials|id_rsa'
  " 2>/dev/null || echo '?')
  if [[ "$secret_pages" == "0" ]]; then
    pass "no secret-looking file made it into the index"
  elif [[ "$secret_pages" == "?" ]]; then
    soft "could not check for indexed secrets"
  else
    fail "$secret_pages page(s) look like secret files" \
         "List them, add to sparse-excludes, re-run bootstrap.sh + refresh.sh, then purge the pages."
  fi
fi

# ------------------------------------------------------------- reranker ----

if [[ "$RERANKER" != "none" ]]; then
  log "Reranker"
fi

if [[ "$RERANKER" == "local" ]]; then
  # Start it the way serve.sh does rather than reporting on whatever happened to
  # be running. Otherwise this check answers "did someone open an agent session
  # recently", which is not the question.
  if reranker_ensure_running; then
    pass "reranker answers a real /v1/rerank call on :$RERANK_PORT"
  else
    soft "reranker not responding on :$RERANK_PORT" \
         "Model file missing from the cache, llama-server not installed, or it did not load in 25s. /health lies during model load — this check uses a real rerank call, which is why it is trustworthy."
  fi

  # Running is only half of it: gbrain calls a reranker only when the config
  # points at one. A started-but-unwired reranker burns memory and never
  # receives a request, and nothing at query time says so.
  rr_on=$(gbrain config get search.reranker.enabled 2>/dev/null | tr -d '[:space:]')
  rr_model=$(gbrain config get search.reranker.model 2>/dev/null | tr -d '[:space:]')
  rr_url=$(gbrain config get provider_base_urls.llama-server-reranker 2>/dev/null | tr -d '[:space:]')
  want_model="llama-server-reranker:$(reranker_alias)"
  if [[ "$rr_on" == *true ]] && [[ "$rr_model" == *"$want_model" ]] && [[ "$rr_url" == *":$RERANK_PORT/v1" ]]; then
    pass "gbrain is wired to the local reranker ($want_model)"
  else
    fail "gbrain is not wired to the local reranker" \
         "Expected search.reranker.enabled=true, search.reranker.model=$want_model, provider_base_urls.llama-server-reranker=http://127.0.0.1:$RERANK_PORT/v1. Run scripts/setup.sh to write them. Until then the process runs but never gets a request, and search silently falls back to RRF order."
  fi
fi

if [[ "$RERANKER" == "hosted" ]]; then
  rr_on=$(gbrain config get search.reranker.enabled 2>/dev/null | tr -d '[:space:]')
  rr_model=$(gbrain config get search.reranker.model 2>/dev/null | tr -d '[:space:]')
  if [[ "$rr_on" == "true" ]]; then
    pass "search.reranker.enabled=true, model=${rr_model:-<unset>}"
  else
    fail "search.reranker.enabled is '${rr_on:-<unset>}'" "run scripts/bootstrap.sh"
  fi
  # The failure mode here is silent by design: a missing key makes every rerank
  # call fail OPEN, so search keeps answering in RRF order and nothing errors.
  rr_key_var="${RERANK_KEY_VAR:-OPENROUTER_API_KEY}"
  if [[ -n "${!rr_key_var:-}" ]]; then
    pass "$rr_key_var present"
  else
    fail "$rr_key_var is not set" \
         "Rerank calls fail open — search still answers, just without the precision the reranker buys. Nothing will tell you at query time."
  fi
fi

# ---------------------------------------------------------- retrieval ----

log "Retrieval over MCP stdio (the path agents actually use)"

probe="$(mcp_query_all "$PROBE_TOKEN" 3 2>/dev/null || true)"
if [[ -z "$probe" ]]; then
  fail "the MCP server did not answer" "try running scripts/serve.sh by hand to see the error"
elif mcp_response_has_hits "$probe"; then
  pass "cross-source __all__ returns results"
else
  fail "cross-source __all__ returned NOTHING" \
       "This is the #1 silent killer: agents get empty answers with no error. See docs/TRAPS.md, then ./scripts/patch-stdio-trust.sh --status"
fi

# A real question against real content. Uses the first manifest source's id as
# a search term, which any indexed repo should surface something for.
first_id="$(manifest_ids | head -1 || true)"
if [[ -n "$first_id" ]]; then
  hit="$(mcp_query_all "how is $first_id structured" 3 2>/dev/null || true)"
  if mcp_response_has_hits "$hit"; then
    pass "a natural-language question returns content"
  else
    soft "a natural-language question returned nothing" \
         "If the corpus is indexed, suspect the reranker (half-loaded returns empty) or embedding coverage."
  fi
fi

# --------------------------------------------------------------- doctor ----

log "gbrain doctor"
if doctor_out="$(gbrain doctor 2>&1)"; then
  pass "doctor reports healthy"
else
  soft "doctor reported problems" "$(printf '%s' "$doctor_out" | tail -5)"
fi

# -------------------------------------------------------------- summary ----

echo
printf '  %s%d passed%s' "$C_GREEN" "$PASS" "$C_RESET"
(( WARN > 0 )) && printf ' · %s%d warning%s' "$C_YELLOW" "$WARN" "$C_RESET"
(( FAIL > 0 )) && printf ' · %s%d FAILED%s' "$C_RED" "$FAIL" "$C_RESET"
echo; echo

exit $(( FAIL > 0 ? 1 : 0 ))
