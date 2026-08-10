#!/usr/bin/env bash
# Expose this brain to Claude Code in one or more working directories.
#
#   ./scripts/register-mcp.sh ~/work/api ~/work/web
#   ./scripts/register-mcp.sh --list
#   ./scripts/register-mcp.sh --remove ~/work/api
#
# Registers scripts/serve.sh (never bare `gbrain serve`, which would talk to
# whichever brain owns ~/.gbrain) under the local scope, so the registration
# lives in that directory's config and does not leak to other projects.
#
# Claude Code's `local` scope keys on the current working directory, so this
# script cds into each target before registering.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
load_conf

need claude "Claude Code CLI not found"

SERVER_NAME="${MCP_NAME:-$BRAIN_ID}"
ENTRY="$HERE/serve.sh"
[[ -x "$ENTRY" ]] || die "$ENTRY is not executable — run: chmod +x scripts/*.sh"

case "${1:-}" in
  --list)
    log "MCP servers registered in $(pwd)"
    claude mcp list
    exit 0
    ;;
  --remove)
    shift
    (( $# > 0 )) || die "usage: $0 --remove <dir>..."
    for dir in "$@"; do
      [[ -d "$dir" ]] || { warn "not a directory: $dir"; continue; }
      ( cd "$dir" && claude mcp remove "$SERVER_NAME" -s local >/dev/null 2>&1 ) \
        && ok "removed from $dir" || warn "not registered in $dir"
    done
    exit 0
    ;;
  '')
    die "usage: $0 <project-dir>...    (or --list / --remove <dir>...)"
    ;;
esac

log "Registering '$SERVER_NAME' -> $ENTRY"
for dir in "$@"; do
  if [[ ! -d "$dir" ]]; then
    warn "not a directory: $dir"
    continue
  fi
  abs="$(cd "$dir" && pwd -P)"
  if ( cd "$abs" && claude mcp list 2>/dev/null | grep -q "^$SERVER_NAME\b" ); then
    dim "already registered in $abs"
    continue
  fi
  if ( cd "$abs" && claude mcp add "$SERVER_NAME" -s local -- "$ENTRY" >/dev/null ); then
    ok "$abs"
  else
    warn "failed to register in $abs"
  fi
done

echo
log "Next"
info "Paste docs/AGENT-POLICY.md into each project's CLAUDE.md so agents know"
info "to search the brain first — and, critically, to pass source_id \"__all__\"."
info "Without that line in the policy, agents scope every query to the inbox"
info "and conclude the brain is empty."
echo
