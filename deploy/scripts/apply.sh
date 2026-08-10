#!/usr/bin/env bash
# Server-side entry point for remote triggers: pull the brain repo, then do
# what was asked. Invoked over SSH by .github/workflows/brain.yml, and safe to
# run by hand on the server.
#
#   ./deploy/scripts/apply.sh refresh              index every source   (default)
#   ./deploy/scripts/apply.sh refresh api-v5       index just that one — fast
#   ./deploy/scripts/apply.sh apply                manifest changed → bootstrap, then index
#   ./deploy/scripts/apply.sh verify               smoke tests only, no writes
#
# Everything runs inside the compose stack, so the host needs nothing beyond
# docker and this checkout.

set -euo pipefail

BRAIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$BRAIN_DIR"

ACTION="${1:-refresh}"
SOURCE="${2:-}"
case "$ACTION" in refresh|apply|verify) ;; *) echo "unknown action '$ACTION' (refresh|apply|verify)" >&2; exit 2 ;; esac

# Whatever arrives over SSH is untrusted input by the time it reaches a shell
# command, so constrain it to the shape a gbrain source id can legally take.
if [[ -n "$SOURCE" ]] && ! [[ "$SOURCE" =~ ^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$ ]]; then
  echo "invalid source id '$SOURCE'" >&2; exit 2
fi

echo "==> $ACTION${SOURCE:+ (source: $SOURCE)}  in $BRAIN_DIR  ($(date -u +%FT%TZ))"

# A serialised lock. Two overlapping refreshes are not dangerous — gbrain takes
# a per-source lock — but they queue on each other and turn a 30-second job
# into a confusing multi-minute one. `flock` without -w fails fast instead.
LOCK="$BRAIN_DIR/db/.apply.lock"
mkdir -p "$(dirname "$LOCK")"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "!! another apply is already running — exiting without doing anything"
  exit 0
fi

# Pull the manifest and any other config change. --ff-only on purpose: if the
# server's checkout has diverged (usually because agent-written notes were
# committed here and not pushed), stop and let a human look rather than
# merging blind.
echo "==> git pull"
if ! git pull --ff-only; then
  echo "!! git pull --ff-only failed. The checkout has diverged from origin."
  echo "!! Most often: notes were committed on the server and never pushed."
  echo "!!   git -C $BRAIN_DIR log --oneline origin/HEAD..HEAD"
  exit 1
fi

cd "$BRAIN_DIR/deploy"

SCOPE=()
[[ -n "$SOURCE" ]] && SCOPE=(--source "$SOURCE")

case "$ACTION" in
  apply)
    # The manifest or the exclusions changed: reconcile clones, sources,
    # sparse-checkout and tracked branches before indexing. Always brain-wide —
    # a manifest change can add or re-point any source, so scoping it would
    # leave the rest inconsistent with what was just merged.
    echo "==> bootstrap"
    docker compose run --rm bootstrap
    echo "==> refresh"
    docker compose run --rm refresh
    ;;
  refresh)
    docker compose run --rm refresh "${SCOPE[@]+"${SCOPE[@]}"}"
    ;;
  verify)
    docker compose run --rm --entrypoint /brain/scripts/verify.sh refresh
    ;;
esac

echo "==> done ($(date -u +%FT%TZ))"
