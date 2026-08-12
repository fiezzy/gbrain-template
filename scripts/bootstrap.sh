#!/usr/bin/env bash
# Reconcile reality to the config: install gbrain, create the Postgres cluster
# and the brain, clone every repo in sources.manifest, register them as gbrain
# sources, apply the sparse-checkout exclusions, and diagnose the stdio trust
# posture. Idempotent — safe to re-run after editing the manifest.
#
#   ./scripts/bootstrap.sh
#
# Does NOT index anything. Run scripts/refresh.sh afterwards.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/mcp-probe.sh
source "$HERE/lib/mcp-probe.sh"
load_conf

REBRANCHED=()

# ------------------------------------------------------------ preflight ----

log "Preflight"
need git
need curl
need bun "install from https://bun.sh"
if [[ "$PG_MANAGED" == "1" ]]; then
  PGBIN="$(pg_bin_dir)"
  info "postgres      $PGBIN (managed by this brain)"
else
  need psql "postgresql-client is required to talk to $PG_HOST:$PG_PORT"
  PGBIN="$(dirname "$(command -v psql)")"
  info "postgres      $PG_HOST:$PG_PORT (external)"
fi

if [[ "$EMBED_PROFILE" == "local" ]]; then
  need ollama "the local embedding profile needs Ollama — https://ollama.com"
  # `ollama pull` talks to the daemon over HTTP; without it the pull fails with
  # a connection error rather than anything that names the real problem.
  ollama_ensure_running
  ollama_model="${EMBED_MODEL#ollama:}"
  ollama_base="${EMBED_BASE_MODEL:-$ollama_model}"

  if ! ollama_has_model "$ollama_base"; then
    log "Pulling embedding model $ollama_base (once per machine)"
    ollama pull "$ollama_base"
  fi

  # A derived model exists for exactly one reason: batch size. Ollama serves
  # embeddings with a 2048-token batch and the whole request must fit in one,
  # or the model runner is killed — surfacing as "llama-server process no
  # longer running" against whichever page was in flight, with the rest of the
  # import continuing as if nothing happened. gbrain caps chunks at an
  # ESTIMATED 2000 tokens and that estimate undershoots on dense JSON, so the
  # real count lands just over the limit. Measured: 2054-2135 tokens on the
  # chunks that killed it, while much longer code chunks passed.
  #
  # Same weights, so the vectors are interchangeable (verified: cosine
  # 1.000000 against the base). Nothing needs re-embedding when this is
  # introduced to an existing brain.
  if [[ "$ollama_model" != "$ollama_base" ]]; then
    if ollama_has_model "$ollama_model"; then
      dim "derived model $ollama_model"
    else
      log "Creating $ollama_model (num_batch=${EMBED_NUM_BATCH:-4096})"
      modelfile="$(mktemp)"
      printf 'FROM %s\nPARAMETER num_batch %s\n' \
        "$ollama_base" "${EMBED_NUM_BATCH:-4096}" > "$modelfile"
      ollama create "$ollama_model" -f "$modelfile" >/dev/null \
        && ok "$ollama_model" \
        || die "could not create $ollama_model from $ollama_base"
      rm -f "$modelfile"
    fi
  fi
  info "embedder      $EMBED_MODEL (local)"
else
  case "$EMBED_MODEL" in
    voyage:*)        key=VOYAGE_API_KEY ;;
    zeroentropyai:*) key=ZEROENTROPY_API_KEY ;;
    openai:*)        key=OPENAI_API_KEY ;;
    *)               key='' ;;
  esac
  if [[ -n "$key" && -z "${!key:-}" ]]; then
    die "$key is not set — export it, then re-run. Embedding cannot proceed without it."
  fi
  info "embedder      $EMBED_MODEL (hosted, key present)"
fi

if [[ "$RERANKER" == "local" ]]; then
  need llama-server "the local reranker needs llama.cpp — brew install llama.cpp"
fi

# -------------------------------------------------------------- gbrain ----

# `bun install -g` is the documented way in, and it works on a machine that has
# no gbrain. Upgrading an EXISTING install is where it breaks: bun's "global"
# root is $HOME, gbrain is pinned there to a git ref, and asking for a different
# ref of the same package makes bun report
#
#   error: Package "gbrain@github:...#<new>" has a dependency loop
#
# and change nothing. Measured on bun 1.3.11 going 0.42.59.0 -> 0.45.2.0;
# `--force` does not help. Editing the ref in ~/package.json and running a plain
# `bun install` there does work, so that is the fallback — with the manual
# recipe printed if even that fails, because a half-replaced global tool is the
# one outcome worth being loud about.
gbrain_install_pin() {
  local spec="github:garrytan/gbrain#$GBRAIN_PIN"
  bun install -g "$spec" 2>&1 && return 0

  warn "bun install -g failed (usually the dependency-loop bug on an upgrade)"
  local home_manifest="$HOME/package.json"
  if [[ -f "$home_manifest" ]] && grep -q '"gbrain"' "$home_manifest"; then
    info "retrying by repinning $home_manifest"
    cp "$home_manifest" "$home_manifest.bak-$$"
    if python3 - "$home_manifest" "$spec" <<'PY'
import json, sys
path, spec = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d.setdefault('dependencies', {})['gbrain'] = spec
json.dump(d, open(path, 'w'), indent=2)
PY
    then
      ( cd "$HOME" && bun install ) && { rm -f "$home_manifest.bak-$$"; return 0; }
    fi
    mv "$home_manifest.bak-$$" "$home_manifest"
  fi

  die "could not install $GBRAIN_PIN.
    Do it by hand, then re-run this script:
      1. edit ~/package.json so \"gbrain\" points at $spec
      2. cd ~ && bun install
    Nothing was changed. If a previous gbrain is installed it is still intact."
}

log "gbrain $GBRAIN_PIN"
installed=""
command -v gbrain >/dev/null 2>&1 && installed="$(gbrain --version 2>/dev/null | awk '{print $2}')"
want="${GBRAIN_PIN#v}"

if [[ -z "$installed" ]]; then
  info "not installed — installing the pin"
  bun install -g "github:garrytan/gbrain#$GBRAIN_PIN"
elif [[ "$installed" != "$want" ]]; then
  warn "installed gbrain is $installed, this brain pins $want."
  warn "gbrain installs GLOBALLY. Changing it affects EVERY brain on this machine,"
  warn "and it silently discards any local modification of the install — including"
  warn "the stdio-trust patch from scripts/patch-stdio-trust.sh, if applied."
  #
  # Deliberately NOT gated on ASSUME_YES. `--yes` means "do not ask me about
  # THIS brain"; it must not also mean "replace a machine-wide tool other
  # brains depend on". An unattended run therefore keeps what is installed and
  # reports the drift, which is the recoverable outcome. Opting in takes a
  # separate, explicit variable.
  if [[ "${GBRAIN_ALLOW_UPGRADE:-0}" == "1" ]]; then
    info "GBRAIN_ALLOW_UPGRADE=1 — installing $GBRAIN_PIN"
    gbrain_install_pin
  elif [[ "${ASSUME_YES:-0}" == "1" ]]; then
    warn "keeping $installed — an unattended run will not replace a global install."
    warn "To upgrade on purpose: GBRAIN_ALLOW_UPGRADE=1 ./scripts/setup.sh"
  elif confirm "    Install $GBRAIN_PIN now, replacing $installed for every brain?"; then
    gbrain_install_pin
    warn "if this machine had the stdio-trust patch, re-apply it:"
    warn "  ./scripts/patch-stdio-trust.sh --status"
  else
    info "keeping $installed — verify.sh will keep reporting the drift"
  fi
else
  ok "$installed"
fi

# ------------------------------------------------------------ postgres ----

log "Postgres"
mkdir -p "$BRAIN_DIR/db"

if [[ "$PG_MANAGED" == "1" ]]; then
  PWFILE="$BRAIN_DIR/db/.pg-password"
  if [[ ! -f "$PWFILE" ]]; then
    ( umask 077; head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$PWFILE" )
    ok "generated db/.pg-password"
  fi
  chmod 600 "$PWFILE"

  if [[ ! -d "$PGDATA/base" ]]; then
    info "initdb -> $PGDATA"
    mkdir -p "$PGDATA"
    "$PGBIN/initdb" -D "$PGDATA" -U "$PG_USER" -E UTF8 \
      --auth-local=trust --auth-host=scram-sha-256 --pwfile="$PWFILE" >/dev/null
    ok "cluster created"
  else
    ok "cluster exists"
  fi

  # Settings live in their own file, included from postgresql.conf, so this is
  # idempotent: re-running bootstrap rewrites the file rather than appending a
  # second copy of every setting.
  cat > "$PGDATA/gbrain-template.conf" <<PGCONF
# Managed by gbrain-template's bootstrap.sh — edits here are overwritten.
# A dedicated cluster per brain costs ~40MB of overhead and buys a single
# 'rm -rf' teardown.
port = $PG_PORT
listen_addresses = '127.0.0.1'

# No Unix sockets. Everything connects over TCP on loopback, and the socket
# path would otherwise be \$PGDATA/.s.PGSQL.<port>, which silently exceeds the
# 103-byte sun_path limit as soon as the brain lives in a deep directory —
# Postgres then refuses to start at all.
unix_socket_directories = ''
PGCONF

  if ! grep -q "^include 'gbrain-template.conf'" "$PGDATA/postgresql.conf"; then
    printf "\ninclude 'gbrain-template.conf'\n" >> "$PGDATA/postgresql.conf"
  fi
  ok "configured on :$PG_PORT"
fi

pg_ensure_running
ok "reachable at $PG_HOST:$PG_PORT"

if ! PGPASSWORD="$(pg_password)" "$PGBIN/psql" -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
       -d postgres -tAc "select 1 from pg_database where datname='$PG_DB'" 2>/dev/null | grep -q 1; then
  PGPASSWORD="$(pg_password)" "$PGBIN/createdb" -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" "$PG_DB"
  ok "created database $PG_DB"
fi

if ! psql_brain -tAc "create extension if not exists vector" >/dev/null 2>&1; then
  die "could not create the pgvector extension.
    macOS:  brew install pgvector
    Debian: apt install postgresql-17-pgvector
    Then re-run this script."
fi
ok "pgvector"

# --------------------------------------------------------------- brain ----

log "Brain"
if [[ -f "$GBRAIN_CONFIG_DIR/config.json" ]]; then
  ok "already initialized ($GBRAIN_CONFIG_DIR)"
else
  # --non-interactive is required, not merely convenient: since 0.45 `gbrain
  # init` opens a "Search mode preference" wizard and blocks on stdin. That
  # stalls an unattended setup forever, and left to each person it would make
  # retrieval behave differently on every teammate's machine for no visible
  # reason. The mode belongs in brain.conf with everything else the team shares.
  gbrain init --url "$(database_url)" \
    --embedding-model "$EMBED_MODEL" \
    --embedding-dimensions "$EMBED_DIMS" \
    --non-interactive
  ok "initialized at $EMBED_DIMS dimensions"
fi

# Set every run, not just at init: the mode is cheap to write, and a brain that
# was initialised before this setting existed would otherwise keep whatever the
# wizard's default was.
#
# What it controls is the DOWNSTREAM agent's cost, not gbrain's: the cap and
# chunk count decide how much retrieved text lands in the agent's context.
#   conservative  4K cap, 10 chunks
#   balanced      12K cap, 25 chunks
#   tokenmax      no cap, 50 chunks, LLM query expansion (needs an expansion key)
gbrain config set search.mode "${SEARCH_MODE:-balanced}" >/dev/null 2>&1 \
  && ok "search mode: ${SEARCH_MODE:-balanced}" \
  || warn "could not set search.mode — check 'gbrain config show'"

# ------------------------------------------------------------- sources ----

log "Index clones"
mkdir -p "$CLONES_DIR"

while IFS=$'\t' read -r id url branch strategy visibility; do
  clone="$CLONES_DIR/$id"
  if [[ ! -d "$clone/.git" ]]; then
    info "clone $id ($branch)"
    git clone --single-branch --branch "$branch" --depth 50 "$url" "$clone"
  else
    current="$(git -C "$clone" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    if [[ "$current" == "$branch" ]]; then
      dim "exists $id ($branch)"
    else
      # Clones are --single-branch, so origin's refspec only fetches the OLD
      # branch. Widen it before fetching or the new branch stays invisible and
      # refresh.sh keeps pulling the old one.
      info "rebranch $id: $current -> $branch"
      git -C "$clone" remote set-branches origin "$branch"
      git -C "$clone" fetch --depth 50 origin "$branch"
      git -C "$clone" checkout -B "$branch" "origin/$branch"
      git -C "$clone" branch --set-upstream-to "origin/$branch" "$branch" >/dev/null
      if [[ "$current" != "?" && "$current" != "HEAD" ]]; then
        git -C "$clone" branch -D "$current" >/dev/null 2>&1 || true
      fi
      REBRANCHED+=("$id")
    fi
  fi
done < <(manifest_rows)

log "Source registration"
registered="$(gbrain sources list 2>/dev/null || true)"
source_known() { grep -qE "(^|[^a-z0-9-])$1([^a-z0-9-]|$)" <<<"$registered"; }

# Visibility is the manifest's fifth column: it sets gbrain's per-source
# federation flag (`--federated` / `--no-federated`).
#
# What that flag is DOCUMENTED to do is restrict a source to explicitly-named
# queries. What it was MEASURED to do on v0.42.x is less: an unfederated source
# still answers unqualified queries and still appears under source_id "__all__",
# over MCP and on the CLI alike. So treat `isolated` as a label that shows up in
# `gbrain sources list`, not as a filter you can rely on. The mechanism that
# does scope reliably is an explicit source_id. See docs/TRAPS.md.
while IFS=$'\t' read -r id url branch strategy visibility; do
  if source_known "$id"; then
    dim "registered $id ($visibility)"
  else
    info "register $id ($visibility)"
    if [[ "$visibility" == "isolated" ]]; then
      gbrain sources add "$id" --path "$CLONES_DIR/$id" --no-federated
    else
      gbrain sources add "$id" --path "$CLONES_DIR/$id" --federated
    fi
  fi
done < <(manifest_rows)

# Visibility and tracked branch can both change after registration; reconcile
# them every run so editing the manifest is enough.
#
# tracked_branch matters beyond bookkeeping: gbrain's GitHub webhook endpoint
# compares the pushed ref against it and silently answers 202 "ignored" when
# they differ. It defaults to 'main', so a source tracking `dev` or a release
# branch would drop every webhook until this is set.
#
# Re-read the source list first: the copy above was taken BEFORE the sources
# were added, so on a first run every id would look unknown and this whole
# reconcile would be skipped.
registered="$(gbrain sources list 2>/dev/null || true)"

while IFS=$'\t' read -r id url branch strategy visibility; do
  if ! source_known "$id"; then
    warn "$id was not registered — skipping its visibility/branch reconcile"
    continue
  fi
  if [[ "$visibility" == "isolated" ]]; then
    gbrain sources unfederate "$id" >/dev/null 2>&1 \
      || warn "$id: could not set visibility to isolated"
  else
    gbrain sources federate "$id" >/dev/null 2>&1 \
      || warn "$id: could not set visibility to federated"
  fi
  gbrain sources tracked-branch "$id" --set "$branch" >/dev/null 2>&1 \
    || warn "$id: could not set tracked_branch to '$branch' — GitHub webhooks for this source would be dropped as ref_mismatch"
done < <(manifest_rows)

# The inbox: notes written by agents and humans, markdown, git-versioned, and
# the ONLY writable source. The rule this encodes is that memory never writes
# into imported code sources — those are derived caches of git, so a write
# into one is lost on the next sync.
mkdir -p "$INBOX_DIR"

# The inbox is ingested with `gbrain import`, not `gbrain sync`: sync requires
# its source path to be the ROOT of a git repository, and the inbox is a
# subdirectory of this one. Import walks the directory directly.
#
# The consequence worth knowing: import has no concept of deletion, so removing
# a note file leaves its page behind. Delete the page too (`gbrain delete
# <slug>`) when you remove a note that matters.
if ! git -C "$BRAIN_DIR" rev-parse HEAD >/dev/null 2>&1; then
  warn "this brain directory is not a git repository with commits."
  warn "Notes in inbox/ are then not versioned anywhere — they are the only"
  warn "content here that cannot be rebuilt. Run: git init && git add -A && git commit"
fi
if source_known inbox; then
  dim "registered inbox"
else
  info "register inbox"
  gbrain sources add inbox --path "$INBOX_DIR" --federated
fi

# ----------------------------------------------------- sparse exclusions ----

if [[ -f "$SPARSE" ]]; then
  log "Sparse-checkout exclusions"
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    clone="$CLONES_DIR/$id"
    [[ -d "$clone/.git" ]] || continue
    # Every rule for a source must be applied in ONE call: `sparse-checkout
    # set` REPLACES the rule set, so splitting a source's paths across two
    # calls silently resurrects everything from the first batch.
    rules=("/*")
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      # gitignore semantics, and the distinction matters more than it looks.
      # A pattern with a slash is a PLACE — anchor it at the repo root, so
      # `audit/reports` excludes exactly that directory. A bare filename is a
      # KIND — leave it unanchored so it matches at every depth.
      #
      # Anchoring everything, which this used to do, silently let nested copies
      # through: `package-lock.json` became `!/package-lock.json` and matched
      # only the root one, while `scripts/package-lock.json` and
      # `admin-panel/package-lock.json` sailed into the index. Beyond the noise,
      # dense generated JSON is what crashes a local embedding runner.
      # A LEADING slash pins the pattern to the repository root and nowhere
      # else, which is the difference between dropping a repo's top-level
      # `scripts/` and also dropping `src/database/scripts/` — real code that
      # merely shares the name.
      if [[ "$path" == /* ]]; then
        rules+=("!$path")
      elif [[ "$path" == */* ]]; then
        rules+=("!/$path")
      else
        rules+=("!$path")
      fi
    done < <(sparse_paths_for "$id")
    git -C "$clone" sparse-checkout set --no-cone "${rules[@]}"
    dim "$id: $(( ${#rules[@]} - 1 )) exclusion(s)"
  done < <(sparse_ids)
fi

# -------------------------------------------------------------- models ----

if [[ "$RERANKER" == "hosted" ]]; then
  log "Reranker"
  # Stored in the brain's own config, so it applies to every transport —
  # stdio and `serve --http` alike. Without the key the rerank call fails
  # open: search still answers, in RRF order, and `gbrain doctor` surfaces it.
  RR_MODEL="${RERANK_HOSTED_MODEL:-openrouter:cohere/rerank-v3.5}"
  RR_KEY_VAR="${RERANK_KEY_VAR:-OPENROUTER_API_KEY}"
  gbrain config set search.reranker.enabled true >/dev/null 2>&1 \
    && gbrain config set search.reranker.model "$RR_MODEL" >/dev/null 2>&1 \
    && ok "$RR_MODEL" \
    || warn "could not set search.reranker.* — check 'gbrain config show'"
  [[ -n "${!RR_KEY_VAR:-}" ]] \
    || warn "$RR_KEY_VAR is not set: every rerank call will fail open and search falls back to RRF order"
fi

if [[ "$RERANKER" == "local" ]]; then
  log "Reranker model"
  CACHE="${GBRAIN_MODEL_CACHE:-$HOME/.cache/gbrain/models}"
  mkdir -p "$CACHE"
  MODEL_PATH="$CACHE/$RERANK_MODEL_FILE"
  if [[ -f "$MODEL_PATH" ]]; then
    ok "$RERANK_MODEL_FILE (shared cache)"
  else
    info "downloading $RERANK_MODEL_FILE -> $CACHE"
    curl -fL --progress-bar "$RERANK_MODEL_URL" -o "$MODEL_PATH.part"
    mv "$MODEL_PATH.part" "$MODEL_PATH"
    ok "downloaded"
  fi
fi

# ------------------------------------------------------- trust fixture ----

# A fixture page the trust probe and verify.sh both look for. See
# docs/TRAPS.md ("cross-source search returns nothing") for the background.
PROBE_TOKEN="GBRAINTEMPLATEPROBE7F3AD2"
PROBE_SLUG="gbrain-template-trust-probe"

if [[ ! -f "$INBOX_DIR/$PROBE_SLUG.md" ]]; then
  log "Trust fixture"
  cat > "$INBOX_DIR/$PROBE_SLUG.md" <<EOF
---
type: note
title: gbrain-template stdio trust probe
---

# gbrain-template stdio trust probe

Fixture page. bootstrap.sh and verify.sh query for the token below through a
real MCP stdio session scoped to \`source_id: "__all__"\`. If it comes back,
cross-source retrieval works for agents. If it does not, the stdio transport
is refusing to span federated sources — see docs/TRAPS.md.

Marker: $PROBE_TOKEN
EOF
  ok "inbox/$PROBE_SLUG.md"
fi

GBRAIN_SOURCE=inbox gbrain import "$INBOX_DIR" >/dev/null 2>&1 || true
gbrain embed --stale --source inbox >/dev/null 2>&1 || true

# ------------------------------------------------------------- summary ----

echo
if (( ${#REBRANCHED[@]} )); then
  warn "Branch changed for: ${REBRANCHED[*]}"
  warn "Run the NORMAL scripts/refresh.sh next — do NOT pass --full."
  warn "gbrain diffs the sync anchor tree-to-tree against HEAD, so an incremental"
  warn "run applies the exact net delta including deletions. A --full run cannot:"
  warn "its delete-reconcile keys on pages.source_path, which the code importer"
  warn "never writes, so stale code pages would survive forever. See docs/TRAPS.md."
  echo
fi

log "Bootstrap complete"
info "1. ./scripts/refresh.sh                    index everything (first run is slow)"
info "2. ./scripts/verify.sh                     smoke tests, including the stdio trust probe"
info "3. ./scripts/register-mcp.sh <dir>...      expose this brain to Claude Code"
echo
