#!/usr/bin/env bash
# OPT-IN, REVERSIBLE local modification of your gbrain install.
#
# Run this ONLY when scripts/verify.sh reports that cross-source search returns
# nothing over MCP. It applies upstream PR #2652 to the copy of gbrain on this
# machine: one line, `remote: true` -> `remote: false`, on the stdio dispatch
# path.
#
#   ./scripts/patch-stdio-trust.sh            apply (asks first)
#   ./scripts/patch-stdio-trust.sh --revert   restore the backup
#   ./scripts/patch-stdio-trust.sh --status   report only, change nothing
#
# READ THIS BEFORE RUNNING
#
#   * gbrain is installed GLOBALLY (bun install -g). This edits that shared
#     install, so it affects every brain on this machine, not just this one.
#   * A `bun install -g gbrain` reinstall or a version bump silently reverts
#     it. Re-run this script afterwards if verify.sh starts failing again.
#   * A backup is written next to the file and --revert restores it.
#
# WHAT IT CHANGES AND WHY
#
#   The stdio MCP transport marks its callers remote/untrusted, deliberately —
#   the maintainer's reasoning is in the code comment right there. One
#   consequence is severe for a multi-source brain: for an untrusted caller
#   `source_id: "__all__"` spans only *granted* sources, and a local stdio
#   agent holds no grants, so cross-source queries come back empty with no
#   error. Upstream PR #2652 treats stdio as the trusted local pipe it is.
#   It is open and unmerged.
#
#   Whether you need it is an empirical question, not a version question: a
#   later fix (#3242/#3301) made federated pages visible to no-grant MCP
#   callers and may resolve the symptom on its own. verify.sh measures it.
#   Do not run this script speculatively.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/mcp-probe.sh
source "$HERE/lib/mcp-probe.sh"
load_conf

MARK='GBRAIN-TEMPLATE-PATCH'
PROBE_TOKEN="GBRAINTEMPLATEPROBE7F3AD2"

resolve_server_ts() {
  local bin root
  bin="$(command -v gbrain)" || die "gbrain is not on PATH"
  # readlink -f is GNU; fall back to a manual resolve on macOS without coreutils
  if readlink -f "$bin" >/dev/null 2>&1; then
    bin="$(readlink -f "$bin")"
  else
    while [[ -L "$bin" ]]; do bin="$(readlink "$bin")"; done
  fi
  root="$(dirname "$bin")"
  for candidate in "$root/mcp/server.ts" "$root/../mcp/server.ts" "$root/src/mcp/server.ts"; do
    [[ -f "$candidate" ]] && { (cd "$(dirname "$candidate")" && printf '%s/%s' "$(pwd -P)" "$(basename "$candidate")"); return; }
  done
  return 1
}

SERVER_TS="$(resolve_server_ts || true)"
BACKUP="${SERVER_TS:-}.gbrain-template.bak"

status() {
  log "Status"
  info "gbrain      $(gbrain --version 2>/dev/null || echo '?')"
  if [[ -z "$SERVER_TS" ]]; then
    warn "could not locate gbrain's mcp/server.ts — nothing to patch"
    return 1
  fi
  info "server.ts   $SERVER_TS"
  if grep -q "$MARK" "$SERVER_TS"; then
    ok "patch is APPLIED"
  else
    info "patch is NOT applied"
  fi
  [[ -f "$BACKUP" ]] && info "backup      $BACKUP"

  log "Probing cross-source retrieval over MCP stdio"
  if mcp_response_has_hits "$(mcp_query_all "$PROBE_TOKEN" 3 || true)"; then
    ok "__all__ spans sources — you do NOT need this patch"
    return 0
  fi
  warn "__all__ returned nothing"
  warn "If the brain is indexed and inbox/gbrain-template-trust-probe.md exists,"
  warn "this is the symptom PR #2652 addresses."
  return 1
}

case "${1:-}" in
  --status)
    status || true
    exit 0
    ;;

  --revert)
    [[ -n "$SERVER_TS" ]] || die "could not locate gbrain's mcp/server.ts"
    [[ -f "$BACKUP" ]] || die "no backup at $BACKUP — nothing to revert to"
    cp "$BACKUP" "$SERVER_TS"
    ok "reverted $SERVER_TS from backup"
    exit 0
    ;;

  ''|--apply) ;;
  *) die "unknown argument '$1' (--apply | --revert | --status)" ;;
esac

# ---------------------------------------------------------------- apply ----

[[ -n "$SERVER_TS" ]] || die "could not locate gbrain's mcp/server.ts"

if grep -q "$MARK" "$SERVER_TS"; then
  ok "already patched — nothing to do"
  exit 0
fi

# Anchor on the stdio dispatch, then walk back to its `remote: true`. Anchoring
# this way survives comments being added between the two lines, which is
# exactly what happened between 0.42.59 and 0.42.73 and would have broken a
# naive text substitution.
line_stdio="$(grep -n "transport: 'stdio'" "$SERVER_TS" | head -1 | cut -d: -f1 || true)"
[[ -n "$line_stdio" ]] || die "no stdio dispatch found in $SERVER_TS — gbrain's layout changed; apply PR #2652 by hand"

target=""
for (( i = line_stdio; i > line_stdio - 12 && i > 0; i-- )); do
  if sed -n "${i}p" "$SERVER_TS" | grep -q 'remote: true,'; then target="$i"; break; fi
done
[[ -n "$target" ]] || die "no 'remote: true' within 12 lines above the stdio dispatch — apply PR #2652 by hand"

echo
log "About to change ONE line in your global gbrain install"
info "file: $SERVER_TS"
info "line: $target"
info "from: $(sed -n "${target}p" "$SERVER_TS" | sed 's/^[[:space:]]*//')"
info "to:   remote: false,   // $MARK (upstream PR #2652)"
echo
confirm "    Apply?" || { info "aborted"; exit 0; }

cp "$SERVER_TS" "$BACKUP"
perl -i -pe "if (\$. == $target) { s{remote: true,}{remote: false, // $MARK: stdio is a trusted local pipe (upstream PR #2652)} }" "$SERVER_TS"

if ! grep -q "$MARK" "$SERVER_TS"; then
  cp "$BACKUP" "$SERVER_TS"
  die "substitution did not take — restored from backup, apply PR #2652 by hand"
fi

ok "patched (backup: $BACKUP)"

log "Re-probing"
if mcp_response_has_hits "$(mcp_query_all "$PROBE_TOKEN" 3 || true)"; then
  ok "cross-source __all__ now works over stdio"
else
  warn "still empty — the patch was not the (only) problem."
  warn "Revert with: ./scripts/patch-stdio-trust.sh --revert"
  exit 1
fi
