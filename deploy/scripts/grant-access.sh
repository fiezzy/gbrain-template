#!/usr/bin/env bash
# Give one person access to the deployed brain, and print the single command
# they run to wire up their agent.
#
#   ./grant-access.sh ivan                              read everything, write to their own notes
#   ./grant-access.sh ivan --read acme-api,acme-web     read only those sources
#   ./grant-access.sh ci   --read-only                  no write authority at all
#   ./grant-access.sh --list
#   ./grant-access.sh --revoke ivan
#
# Run this on the server, from the deploy/ directory, with the stack up.
#
# THE ACCESS MODEL, BRIEFLY
#
#   Two independent axes, both enforced in SQL rather than by agent good
#   behaviour:
#     --source <id>            where this person may WRITE
#     --federated-read <ids>   what this person may READ
#
#   The important limitation: within a SINGLE source, reads are not sliced.
#   Prefix binding fences writes, not visibility. So if a repository must be
#   invisible to someone, it has to be its OWN source and left out of their
#   --federated-read list. There is no way to hide part of a source.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[[ -f .env ]] || { echo "no .env here — run from deploy/ on the server" >&2; exit 1; }
# shellcheck disable=SC1091
set -a; source .env; set +a

# Where clients actually reach this brain. On a server that is the domain; in a
# local rehearsal it is localhost, or a tunnel URL. Must match the server's
# --public-url or the OAuth handshake fails.
ENDPOINT="${PUBLIC_URL:-https://${DOMAIN:-<domain>}}"

dc() { docker compose "$@"; }
gb() { dc exec -T gbrain gbrain "$@"; }

case "${1:-}" in
  --list)
    # Note: `gbrain auth list` shows legacy bearer TOKENS, not OAuth clients.
    # There is no CLI that lists OAuth clients in this version — the registered
    # clients, their scopes and their live request log are on the admin
    # dashboard at https://$DOMAIN/admin.
    echo "Bearer tokens (legacy auth):"
    gb auth list || true
    echo
    echo "OAuth clients are listed at $ENDPOINT/admin — no CLI equivalent."
    exit 0
    ;;
  --revoke)
    person="${2:?usage: $0 --revoke <name>}"
    gb auth revoke-client "$person"
    echo "revoked: $person"
    exit 0
    ;;
  '' | -h | --help)
    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

PERSON="$1"; shift
[[ "$PERSON" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "name must be [a-z0-9-]" >&2; exit 1; }

READ_SOURCES=""
SCOPES="read write"
WRITE_SOURCE="notes-$PERSON"

while (( $# )); do
  case "$1" in
    --read)       READ_SOURCES="$2"; shift 2 ;;
    --read-only)  SCOPES="read"; WRITE_SOURCE=""; shift ;;
    --write-to)   WRITE_SOURCE="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Default read scope: every registered source. Narrow it with --read when
# somebody should not see everything.
if [[ -z "$READ_SOURCES" ]]; then
  READ_SOURCES=$(gb sources list 2>/dev/null \
    | awk 'NR>1 && $1 ~ /^[a-z0-9][a-z0-9-]*$/ {print $1}' | paste -sd, -)
  echo "read scope defaults to every source: $READ_SOURCES"
fi

# A personal notes source, so one person's writes cannot land on top of
# another's. Creating it is idempotent enough to just try.
if [[ -n "$WRITE_SOURCE" ]]; then
  if ! gb sources list 2>/dev/null | grep -qE "(^|[^a-z0-9-])$WRITE_SOURCE([^a-z0-9-]|$)"; then
    mkdir -p "../notes/$PERSON"
    gb sources add "$WRITE_SOURCE" --path "/brain/notes/$PERSON" --federated
    echo "created write source: $WRITE_SOURCE -> notes/$PERSON/"
    READ_SOURCES="$READ_SOURCES,$WRITE_SOURCE"
  fi
fi

echo
echo "Registering OAuth client '$PERSON'"
echo "  scopes:  $SCOPES"
echo "  writes:  ${WRITE_SOURCE:-<none>}"
echo "  reads:   $READ_SOURCES"
echo

args=(auth register-client "$PERSON" --grant-types client_credentials --scopes "$SCOPES")
[[ -n "$WRITE_SOURCE" ]] && args+=(--source "$WRITE_SOURCE")
args+=(--federated-read "$READ_SOURCES")

# The credentials are shown exactly once — the secret is hashed on storage.
gb "${args[@]}"

cat <<EOF

------------------------------------------------------------------
Send this to $PERSON.

NOTHING GETS INSTALLED on their machine — no gbrain, no database, no
models, no clones. Claude Code talks to this server over HTTP, so all
they need is Claude Code itself. They run, in their project directory:

  claude mcp add ${BRAIN_ID:-brain} -t http $ENDPOINT/mcp \\
    --client-id     <client_id from above> \\
    --client-secret <client_secret from above>

Then they paste docs/AGENT-POLICY.md into that project's CLAUDE.md.
Without it their agent will not pass source_id "__all__", will search
only the notes, and will report that the brain is empty.

To check it took, ask the agent to search for something you know is
indexed.

The secret above is shown ONCE — it is hashed on storage. If it is
lost, revoke and re-issue:
  ./grant-access.sh --revoke $PERSON && ./grant-access.sh $PERSON

Change what they can see later, without touching their secret:
  docker compose exec gbrain gbrain auth rescope-client <client_id> \\
    --federated-read <source-ids>
------------------------------------------------------------------
EOF
