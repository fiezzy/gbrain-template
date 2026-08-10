#!/usr/bin/env bash
# One-time parameterization: turn this clone of gbrain-template into a brain
# for a specific project. Writes brain.conf, sources.manifest and
# sparse-excludes, then stops. Nothing outside this directory is touched —
# scripts/bootstrap.sh does the actual work.
#
#   ./scripts/init.sh                 interactive
#   ./scripts/init.sh --force         overwrite an existing brain.conf
#
# Non-interactive (CI / scripted):
#   BRAIN_ID=acme EMBED_PROFILE=hosted EMBED_PROVIDER=voyage \
#   REPOS="git@github.com:acme/api.git main code
#          git@github.com:acme/web.git  main code" \
#   ASSUME_YES=1 ./scripts/init.sh

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ -f "$CONF" && $FORCE -eq 0 ]]; then
  die "brain.conf already exists. Re-run with --force to overwrite, or edit it by hand."
fi

interactive() { [[ -t 0 && "${ASSUME_YES:-0}" != "1" ]]; }

ask() { # ask <var> <prompt> <default>
  local __var="$1" __prompt="$2" __default="$3" __reply
  if [[ -n "${!__var:-}" ]]; then
    printf '    %s: %s (from environment)\n' "$__prompt" "${!__var}"
    return
  fi
  if ! interactive; then
    printf -v "$__var" '%s' "$__default"
    return
  fi
  read -r -p "    $__prompt [$__default]: " __reply
  printf -v "$__var" '%s' "${__reply:-$__default}"
}

echo
printf '%s  gbrain-template — new brain%s\n' "$C_BOLD" "$C_RESET"
echo

# ------------------------------------------------------------ identity ----

log "Identity"
default_id=$(basename "$BRAIN_DIR" | tr '[:upper:]_ ' '[:lower:]--' | sed 's/-brain$//;s/[^a-z0-9-]//g')
ask BRAIN_ID "Brain id (lowercase, used for the DB name and MCP server name)" "${default_id:-brain}"
[[ "$BRAIN_ID" =~ ^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$ ]] \
  || die "invalid id '$BRAIN_ID' — 2-32 chars of [a-z0-9-], must start and end alphanumeric"
ask BRAIN_NAME "Human-readable project name" "$BRAIN_ID"

PG_DB="${PG_DB:-$(tr -- '-' '_' <<<"$BRAIN_ID")_brain}"
PG_USER="${PG_USER:-brain}"

# --------------------------------------------------------------- ports ----

echo
log "Ports (auto-picked to avoid collisions with other brains on this machine)"
PG_PORT="${PG_PORT:-$(free_port_from 5442)}"
info "postgres      :$PG_PORT"

# ----------------------------------------------------------- embeddings ----

echo
log "Embedding provider"
cat <<'TXT'
    This is a one-way door: the vector width is baked into the database
    schema, so changing it later means re-embedding everything from scratch.

      local   Ollama on this machine. Free, nothing leaves the box, RU/EN
              both work. 2560 dimensions — that is ABOVE pgvector's 2000-dim
              HNSW ceiling, so vector search runs as an exact scan. Fine for
              one person on a laptop; it does not scale to a shared server.

      hosted  Voyage / ZeroEntropy / OpenAI. Cents per full re-index, ~1024-1536
              dimensions, so HNSW actually gets built and search stays fast as
              the corpus grows. Required for the server deployment. Your code
              chunks are sent to the provider at index time.
TXT
ask EMBED_PROFILE "Profile (local|hosted)" "local"

case "$EMBED_PROFILE" in
  local)
    EMBED_MODEL="${EMBED_MODEL:-ollama:qwen3-embedding:4b-q8_0}"
    EMBED_DIMS="${EMBED_DIMS:-2560}"
    ;;
  hosted)
    echo
    info "voyage         voyage-code-3, 1024d, \$0.18/1M, tuned on source code"
    info "zeroentropyai  2560d Matryoshka -> set 1280 to stay under the HNSW cap, \$0.05/1M"
    info "openai         text-embedding-3-large, 1536d, \$0.13/1M"
    ask EMBED_PROVIDER "Provider (voyage|zeroentropyai|openai)" "voyage"
    case "$EMBED_PROVIDER" in
      voyage)        EMBED_MODEL="voyage:voyage-code-3";              EMBED_DIMS="${EMBED_DIMS:-1024}"; KEY_VAR=VOYAGE_API_KEY ;;
      zeroentropyai) EMBED_MODEL="zeroentropyai:zembed-1";            EMBED_DIMS="${EMBED_DIMS:-1280}"; KEY_VAR=ZEROENTROPY_API_KEY ;;
      openai)        EMBED_MODEL="openai:text-embedding-3-large";     EMBED_DIMS="${EMBED_DIMS:-1536}"; KEY_VAR=OPENAI_API_KEY ;;
      *) die "unknown provider '$EMBED_PROVIDER'" ;;
    esac
    [[ -n "${!KEY_VAR:-}" ]] || warn "$KEY_VAR is not set — export it before running bootstrap.sh"
    ;;
  *) die "profile must be 'local' or 'hosted'" ;;
esac
info "model $EMBED_MODEL / ${EMBED_DIMS}d"

if (( EMBED_DIMS > 2000 )); then
  warn "${EMBED_DIMS}d exceeds pgvector's 2000-dim HNSW ceiling — vector search will be an exact scan."
fi

# ------------------------------------------------------------- reranker ----

echo
log "Reranker (optional — improves precision, costs a local process)"
info "local  llama-server with a small GGUF cross-encoder on :PORT, free"
info "none   hybrid RRF only; everything still works, precision is lower"
ask RERANKER "Reranker (local|none)" "local"
RERANK_PORT="${RERANK_PORT:-$(free_port_from 8081)}"
[[ "$RERANKER" == "local" ]] && info "reranker      :$RERANK_PORT"

# -------------------------------------------------------------- sources ----

echo
log "Source repositories"
cat <<'TXT'
    One line per repo. Index the INTEGRATION branch — the branch work lands
    on (main, dev, master). Never a feature branch, never a worktree: the
    index is a shared artifact and feature branches churn.

    Format:  <git-url> [branch] [strategy]     (branch defaults to main,
                                                strategy to code)
    Empty line to finish.
TXT

declare -a ROWS=()
id_taken() {
  (( ${#ROWS[@]} > 0 )) && printf '%s\n' "${ROWS[@]}" | cut -f1 | grep -qxF "$1"
}

add_row() {
  local url="$1" branch="${2:-main}" strategy="${3:-code}" visibility="${4:-federated}"
  local id base
  base=$(basename "$url" .git | tr '[:upper:]_ ' '[:lower:]--' | sed 's/[^a-z0-9-]//g')
  [[ -n "$base" ]] || { warn "could not derive an id from '$url' — skipped"; return; }

  # Indexing two branches of the SAME repo is a real case — a current contract
  # version alongside the one still in production. They need distinct ids
  # because the id names the clone directory, so suffix with the branch.
  id="$base"
  if id_taken "$id"; then
    id="$base-$(tr '[:upper:]/_' '[:lower:]--' <<<"$branch" | sed 's/[^a-z0-9-]//g')"
    local n=2
    while id_taken "$id"; do id="$base-$n"; n=$((n + 1)); done
    info "id '$base' is taken; using '$id' for the $branch branch"
  fi

  ROWS+=("$(printf '%s\t%s\t%s\t%s\t%s' "$id" "$url" "$branch" "$strategy" "$visibility")")
  info "$id  <-  $url ($branch, $strategy, $visibility)"
}

if [[ -n "${REPOS:-}" ]]; then
  while read -r url branch strategy; do
    [[ -z "$url" ]] && continue
    add_row "$url" "${branch:-main}" "${strategy:-code}"
  done <<<"$REPOS"
elif interactive; then
  while true; do
    read -r -p "    repo> " url branch strategy || break
    [[ -z "${url:-}" ]] && break
    add_row "$url" "${branch:-main}" "${strategy:-code}"
  done
fi

(( ${#ROWS[@]} > 0 )) || warn "no repositories yet — add them to sources.manifest before bootstrap"

# --------------------------------------------------------------- write ----

echo
log "Writing configuration"

cat > "$CONF" <<CONF
# Generated by scripts/init.sh. This is the only project-specific file;
# everything else in this repo is the template.
#
# Every value uses \${VAR:=default}, which assigns only when the variable is
# unset. That means the ENVIRONMENT WINS — which is what lets the same checkout
# run locally against a dedicated cluster and, in the server deployment, against
# the Postgres container whose host, port and credentials come from compose.

: "\${BRAIN_ID:=$BRAIN_ID}"
: "\${BRAIN_NAME:=$BRAIN_NAME}"

# Postgres. Locally this brain owns a dedicated cluster in db/pg and starts it
# on demand. Set PG_MANAGED=0 (the deploy stack does) when Postgres belongs to
# somebody else and the scripts should only wait for it.
: "\${PG_HOST:=127.0.0.1}"
: "\${PG_PORT:=$PG_PORT}"
: "\${PG_DB:=$PG_DB}"
: "\${PG_USER:=$PG_USER}"
: "\${PG_MANAGED:=1}"

# Embeddings. Changing these after the first index requires a full re-embed
# (gbrain retrieval-upgrade --to <model> --reindex), so they are deliberately
# NOT environment-overridable — a stray env var must not be able to point an
# existing database at a different vector width.
EMBED_PROFILE=$EMBED_PROFILE
EMBED_MODEL=$EMBED_MODEL
EMBED_DIMS=$EMBED_DIMS

# Reranker: local | none
: "\${RERANKER:=$RERANKER}"
: "\${RERANK_PORT:=$RERANK_PORT}"

# Pinned gbrain. NOTE: gbrain installs globally (bun install -g), so this pin
# is machine-wide, not per-brain. verify.sh reports drift; nothing enforces it.
: "\${GBRAIN_PIN:=v0.42.73.2}"

# Reranker model, downloaded once into a shared cache (~/.cache/gbrain/models)
# so N brains on this machine do not each keep their own copy.
: "\${RERANK_MODEL_FILE:=Qwen3-Reranker-0.6B.Q8_0.gguf}"
: "\${RERANK_MODEL_URL:=https://huggingface.co/Voodisss/Qwen3-Reranker-0.6B-GGUF/resolve/main/Qwen3-Reranker-0.6B.Q8_0.gguf}"
: "\${RERANK_CTX:=8192}"
CONF
ok "brain.conf"

{
  cat <<HDR
# Source manifest for $BRAIN_NAME — one line = one indexed source.
#
# Format: <id>⇥<git-url>⇥<branch>⇥<strategy>[⇥<visibility>]   TABS, not spaces.
#
# strategy:    code       source files (enables code_def / code_refs lookup)
#              markdown   .md/.mdx only
#              auto       both
#
# visibility:  federated  (default) · isolated  sets gbrain's federation flag.
#              MEASURED CAVEAT: 'isolated' does NOT hide a source from queries.
#              It still answers unqualified queries and source_id "__all__".
#              Treat it as a label, not a filter — see docs/TRAPS.md.
#
# Policy: index INTEGRATION branches — the branch work lands on. Never a feature
# branch, never a worktree; index the branch their work merges into.
#
# TWO VERSIONS OF THE SAME REPO
# The id names the clone directory, so one repo can appear twice, on two
# branches, under two ids:
#
#   orders-v2⇥git@github.com:acme/orders.git⇥main⇥code
#   orders-v1⇥git@github.com:acme/orders.git⇥release/v1⇥code⇥isolated
#
# Both then answer every unqualified search, so the way to reach exactly one is
# an explicit source_id ("orders-v1"), which DOES scope correctly. Put the
# version in the id, and make sure the code itself says which version it is —
# retrieval cannot tell two near-identical contracts apart on its own.
#
# Change a branch here and re-run bootstrap.sh: it re-points the existing clone
# and tells you what to do next. Add a repo = add a line + bootstrap.sh.
HDR
  (( ${#ROWS[@]} > 0 )) && printf '%s\n' "${ROWS[@]}"
} > "$MANIFEST"
ok "sources.manifest (${#ROWS[@]} source(s))"

{
  cat <<'HDR'
# Paths excluded from indexing, applied via git sparse-checkout on the index
# clones. gbrain has no native exclude mechanism; sparse-checkout removes the
# files from the clone's working tree and gbrain's walker skips ls-files
# entries that are missing on disk.
#
# Format: <source-id>⇥<repo-relative-path>          TABS, not spaces.
# Applied by bootstrap.sh, idempotent, survives refresh.sh pulls.
#
# What belongs here:
#   - lock files and generated JSON/YAML: huge, zero signal, and a single
#     multi-megabyte line can take down a local embedding runner
#   - locale / i18n dictionaries: thousands of near-identical strings that
#     dilute retrieval
#   - vendored or minified bundles
#   - anything with secrets that should never reach the index
HDR
  echo
  if (( ${#ROWS[@]} > 0 )); then
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      for p in package-lock.json yarn.lock pnpm-lock.yaml poetry.lock uv.lock \
               Cargo.lock composer.lock go.sum Gemfile.lock; do
        printf '%s\t%s\n' "$id" "$p"
      done
    done < <(printf '%s\n' "${ROWS[@]}" | cut -f1)
  fi
} > "$SPARSE"
ok "sparse-excludes (lock files seeded for every source)"

mkdir -p "$INBOX_DIR"
[[ -f "$INBOX_DIR/.gitkeep" ]] || touch "$INBOX_DIR/.gitkeep"

# --------------------------------------------------------------- finish ----

echo
log "Next"
info "1. review  sources.manifest  and  sparse-excludes"
if [[ "$EMBED_PROFILE" == "hosted" ]]; then
  info "2. export ${KEY_VAR:-<PROVIDER>_API_KEY}=..."
  info "3. ./scripts/bootstrap.sh    # install gbrain, create the DB, clone + register sources"
  info "4. ./scripts/refresh.sh      # first index"
  info "5. ./scripts/verify.sh       # smoke tests"
else
  info "2. ./scripts/bootstrap.sh    # install gbrain, create the DB, clone + register sources"
  info "3. ./scripts/refresh.sh      # first index"
  info "4. ./scripts/verify.sh       # smoke tests"
fi
info "then  ./scripts/register-mcp.sh <dir>...   to expose this brain to Claude Code"
echo
