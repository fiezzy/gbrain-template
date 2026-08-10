#!/usr/bin/env bash
# MCP entrypoint. This is the command you register with Claude Code (or any
# other MCP client) — never bare `gbrain serve`, which would talk to whichever
# brain happens to own ~/.gbrain.
#
# It exists to make the brain's dependencies lazy and correct:
#
#   GBRAIN_HOME    points gbrain at THIS brain's config and database, which is
#                  what lets several brains coexist on one machine
#   postgres       started on demand; nothing runs at boot
#   reranker       started on demand, shared by every session, left running
#                  (llama-server has no idle exit)
#   GBRAIN_SOURCE  pages written by agents land in the git-backed inbox rather
#                  than the seeded 'default' source
#
# Registered by scripts/register-mcp.sh. Safe to run by hand for debugging.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
load_conf

# MCP clients launch this with a minimal environment; Homebrew is not on PATH.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

# ------------------------------------------------------------- postgres ----

pg_ensure_running

# ------------------------------------------------------------- reranker ----

if [[ "$RERANKER" == "local" ]]; then
  CACHE="${GBRAIN_MODEL_CACHE:-$HOME/.cache/gbrain/models}"
  MODEL_PATH="$CACHE/$RERANK_MODEL_FILE"

  if [[ -f "$MODEL_PATH" ]] && ! reranker_ready; then
    # Concurrent sessions may race to spawn one; the loser fails to bind the
    # port and exits. Harmless.
    nohup llama-server -m "$MODEL_PATH" \
      --alias "${RERANK_MODEL_FILE%.gguf}" \
      --reranking --pooling rank -ngl 99 \
      -b 2048 -ub 2048 -c "${RERANK_CTX:-8192}" \
      --host 127.0.0.1 --port "$RERANK_PORT" \
      >> "$BRAIN_DIR/db/reranker.log" 2>&1 &

    # /health returns ok BEFORE the model finishes loading, and gbrain queries
    # against a half-loaded reranker silently return "No results". Probe with a
    # real rerank call. Capped so we stay under the MCP client's startup
    # timeout — if it is not up by then, serve anyway without it.
    for _ in $(seq 1 25); do
      reranker_ready && break
      sleep 1
    done
  fi
fi

# ---------------------------------------------------------------- serve ----

# Without this, stdio serve writes put_page output to the 'default' source
# instead of the git-backed inbox (gbrain #1436).
export GBRAIN_SOURCE=inbox

exec gbrain serve
