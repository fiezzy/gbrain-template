#!/usr/bin/env bash
# Bring the index up to date: fast-forward every clone to its manifest branch,
# re-sync each source, sweep deferred embeddings, extract links and timeline.
#
#   ./scripts/refresh.sh                    every source (the scheduled case)
#   ./scripts/refresh.sh --source api-v5    just one — for "I merged, index it now"
#   ./scripts/refresh.sh --full             full re-import — read TRAPS.md first
#
# Sync runs PER SOURCE on purpose. `gbrain sync --all` ignores --strategy and
# falls back to markdown-only, which silently reduces a code brain to whatever
# .md files happen to be in the repos. There is no CLI that persists a
# per-source strategy, so the manifest is the only place that knowledge lives
# and the loop below is the only thing that applies it.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
load_conf

# --source is consumed here rather than passed through to gbrain: this script
# drives the per-source loop itself, so the flag has to narrow the loop.
ONLY_SOURCE=""
EXTRA_ARGS=()
while (( $# )); do
  case "$1" in
    --source) ONLY_SOURCE="${2:-}"; shift 2 ;;
    --source=*) ONLY_SOURCE="${1#--source=}"; shift ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

if [[ -n "$ONLY_SOURCE" && "$ONLY_SOURCE" != "inbox" ]]; then
  manifest_ids | grep -qxF "$ONLY_SOURCE" || die "no source '$ONLY_SOURCE' in sources.manifest. Known: $(manifest_ids | paste -sd' ' -) inbox"
fi

# Skip a row when scoped to a different source.
skip_row() { [[ -n "$ONLY_SOURCE" && "$1" != "$ONLY_SOURCE" ]]; }

STARTED=$(date +%s)
[[ -n "$ONLY_SOURCE" ]] && log "Scoped to source: $ONLY_SOURCE"

for a in "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; do
  if [[ "$a" == "--full" ]]; then
    warn "--full cannot delete stale pages for strategy=code sources."
    warn "Its delete-reconcile keys on pages.source_path, which the code importer"
    warn "never writes (it stashes the path in frontmatter->>'file'), so every code"
    warn "page has source_path IS NULL and the reconcile matches nothing."
    warn "Deletions only land through the INCREMENTAL path. See docs/TRAPS.md."
    confirm "    Continue with --full anyway?" || exit 0
  fi
done

pg_ensure_running

# ----------------------------------------------------------------- pull ----

log "Pulling clones"
MISSING=()
while IFS=$'\t' read -r id url branch strategy visibility; do
  skip_row "$id" && continue
  clone="$CLONES_DIR/$id"
  if [[ ! -d "$clone/.git" ]]; then
    MISSING+=("$id")
    warn "missing clone: $id — run scripts/bootstrap.sh"
    continue
  fi
  printf '    %-28s ' "$id"
  if git -C "$clone" pull --ff-only >/dev/null 2>&1; then
    printf '%s\n' "$(git -C "$clone" rev-parse --short HEAD)"
  else
    printf '%spull failed%s\n' "$C_YELLOW" "$C_RESET"
    warn "$id: git pull --ff-only failed (diverged history, or the branch moved)"
  fi
done < <(manifest_rows)

# ----------------------------------------------------------------- sync ----

log "Syncing sources"
SYNC_FAILED=()
while IFS=$'\t' read -r id url branch strategy visibility; do
  skip_row "$id" && continue
  [[ -d "$CLONES_DIR/$id/.git" ]] || continue
  info "$id (strategy=$strategy)"
  if ! gbrain sync --source "$id" --strategy "$strategy" \
       "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; then
    SYNC_FAILED+=("$id")
    warn "$id: sync returned non-zero"
  fi
done < <(manifest_rows)

# The inbox goes through `import`, not `sync`. Sync requires its source path to
# be the ROOT of a git repository and the inbox is a subdirectory of this one,
# so sync fails on it with a misleading "not a git repository". Import walks the
# directory directly and honours GBRAIN_SOURCE.
#
# Import never deletes: removing a note file leaves its page in the index. Drop
# it explicitly with `gbrain delete <slug>` when that matters.
if ! skip_row inbox; then
  info "inbox (import)"
  GBRAIN_SOURCE=inbox gbrain import "$INBOX_DIR" || SYNC_FAILED+=("inbox")
fi

# ---------------------------------------------------------------- embed ----

# Large syncs defer embeddings, and any embedding backend can drop a batch, so
# a sweep is required rather than optional. Since 0.42.69.0 `gbrain embed`
# exits non-zero when content is genuinely un-embeddable — that is a useful
# signal, but it must not abort the whole refresh under `set -e`, and it must
# not be swallowed either. Collect and report at the end.
log "Embedding sweep"
EMBED_DIRTY=()
sweep_source() {
  local id="$1" round out
  for round in 1 2 3; do
    if out="$(gbrain embed --stale --source "$id" 2>&1 | tail -1)"; then
      printf '    %-28s %s\n' "$id" "$out"
      grep -qE '0 stale|no stale|nothing' <<<"$out" && return 0
    else
      printf '    %-28s %s%s%s\n' "$id" "$C_YELLOW" "$out" "$C_RESET"
      EMBED_DIRTY+=("$id")
      return 1
    fi
    sleep 2
  done
  return 0
}

while IFS=$'\t' read -r id url branch strategy visibility; do
  skip_row "$id" && continue
  [[ -d "$CLONES_DIR/$id/.git" ]] || continue
  sweep_source "$id" || true
done < <(manifest_rows)
if ! skip_row inbox; then
  sweep_source inbox || true
fi

# -------------------------------------------------------------- extract ----

log "Extracting links and timeline"
gbrain extract --stale 2>&1 | tail -2 || warn "extract returned non-zero (pages stay searchable; links may lag)"

# -------------------------------------------------------------- summary ----

echo
log "Status"
gbrain sources status 2>/dev/null || gbrain sources list

ELAPSED=$(( $(date +%s) - STARTED ))
echo
printf '    took %dm %ds\n' $((ELAPSED / 60)) $((ELAPSED % 60))

PROBLEMS=0

if (( ${#MISSING[@]} )); then
  warn "missing clones: ${MISSING[*]} — run scripts/bootstrap.sh"
  PROBLEMS=1
fi

if (( ${#SYNC_FAILED[@]} )); then
  warn "sync failed for: ${SYNC_FAILED[*]}"
  warn "Those sources did NOT update — the index still holds their previous state."
  PROBLEMS=1
fi

if (( ${#EMBED_DIRTY[@]} )); then
  warn "un-embeddable content remains in: ${EMBED_DIRTY[*]}"
  warn "Those pages are imported but NOT searchable by vector similarity."
  warn "Usual cause: a single enormous generated file (a lock file, a bundled"
  warn "JSON dictionary, a megastring constant). Find it, add it to"
  warn "sparse-excludes, re-run bootstrap.sh then refresh.sh."
  PROBLEMS=1
fi

if (( PROBLEMS )); then
  echo
  warn "refresh finished with problems — see above"
  exit 1
fi

ok "index up to date"
