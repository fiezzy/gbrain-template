#!/usr/bin/env bash
# Speak real MCP over stdio to `gbrain serve`, the way a coding agent does.
#
# Why this exists: `gbrain call <op>` sets remote=false in cli.ts, so it runs
# on the TRUSTED local path and cannot reproduce what an agent sees. The stdio
# MCP transport marks itself remote/untrusted on purpose, and that changes how
# source scoping resolves — `source_id: "__all__"` spans "every source" for a
# trusted caller but only "your granted sources" for an untrusted one. The
# difference between those two is the difference between a brain that answers
# and a brain that returns nothing, so it has to be tested through the same
# door the agent uses.
#
# Sourced by bootstrap.sh (to decide whether the trust patch is needed) and by
# verify.sh (to prove cross-source retrieval actually works).

# JSON-escape a string. Cyrillic and other UTF-8 pass through raw, which JSON
# permits; only quotes, backslashes and control characters need handling.
json_str() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
  else
    printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g')"
  fi
}

# The entrypoint the probe speaks to. This MUST be scripts/serve.sh, not bare
# `gbrain serve`: serve.sh is what register-mcp.sh hands to Claude Code, and it
# is where Postgres, Ollama and the reranker are started for the session. A probe
# that skipped it would exercise a path no agent ever takes — and would report
# retrieval as healthy while the real entrypoint was broken.
#
# Falls back to bare `gbrain serve` only when serve.sh is missing or not
# executable, which is itself worth seeing in the output.
mcp_serve() {
  local entry="$BRAIN_DIR/scripts/serve.sh"
  if [[ -x "$entry" ]]; then
    exec "$entry"
  else
    exec gbrain serve
  fi
}

# mcp_tool_call <tool> <arguments-json> [timeout-seconds]
# Prints the raw JSON-RPC response line for the call. Returns non-zero if the
# server never answered.
mcp_tool_call() {
  local tool="$1" args="$2" timeout="${3:-45}"
  local out err pid i

  out=$(mktemp); err=$(mktemp)

  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"gbrain-template-probe","version":"1"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$tool" "$args"
    # Hold stdin open: the server exits on EOF, sometimes before it has
    # flushed a slow reply (a cold query embeds the text first).
    sleep "$timeout"
  } | mcp_serve >"$out" 2>"$err" &
  pid=$!

  for ((i = 0; i < timeout; i++)); do
    grep -q '"id":2' "$out" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done

  kill "$pid" 2>/dev/null || true
  pkill -P "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  local line
  line=$(grep '"id":2' "$out" 2>/dev/null | head -1)
  rm -f "$out" "$err"

  [[ -n "$line" ]] || return 1
  printf '%s\n' "$line"
}

# mcp_query_all <query> [limit] — hybrid query scoped across every source.
# Prints the response line; caller decides what "empty" means.
mcp_query_all() {
  local q="$1" limit="${2:-3}"
  mcp_tool_call query \
    "$(printf '{"query":%s,"source_id":"__all__","limit":%s}' "$(json_str "$q")" "$limit")"
}

# True when the response carried at least one result. gbrain returns a JSON
# array inside the MCP text content; an empty result is `[]` or the literal
# "No results".
mcp_response_has_hits() {
  local line="$1"
  [[ -n "$line" ]] || return 1
  grep -q '"isError":true' <<<"$line" && return 1
  grep -q 'No results' <<<"$line" && return 1
  grep -q '\\"slug\\"' <<<"$line"
}
