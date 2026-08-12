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

# --------------------------------------------------------------- ollama ----

# Not just an index-time dependency: every search embeds its query. A stopped
# daemon here means searches return nothing rather than returning less.
if [[ "$EMBED_PROFILE" == "local" ]]; then
  ollama_ensure_running
fi

# ------------------------------------------------------------- reranker ----

if [[ "$RERANKER" == "local" ]]; then
  # Never fatal: a missing reranker costs precision, not answers, and refusing
  # to serve would cost both.
  reranker_ensure_running || true
fi

# ---------------------------------------------------------------- serve ----

# Without this, stdio serve writes put_page output to the 'default' source
# instead of the git-backed inbox (gbrain #1436).
export GBRAIN_SOURCE=inbox

exec gbrain serve
