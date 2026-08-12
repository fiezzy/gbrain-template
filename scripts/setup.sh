#!/usr/bin/env bash
# ONE command to turn a fresh clone of this repo into a working brain.
#
#   ./scripts/setup.sh                        set up, index from scratch
#   ./scripts/setup.sh --snapshot brain.dump  set up, restore a prebuilt index
#   ./scripts/setup.sh ~/work/api ~/work/web  ...and expose it to Claude Code there
#   ./scripts/setup.sh --yes                  never ask; for CI and re-runs
#
# Directories can also be given at the end of the run: when none are passed and
# the run is interactive, it asks which projects to connect the brain to.
#
# WHO RUNS WHAT
#   init.sh   the OWNER, once, on an empty repo. It WRITES brain.conf.
#   setup.sh  EVERYONE ELSE, on a repo that already carries brain.conf.
#             It never writes brain.conf — the committed file is the contract
#             that keeps every teammate's vector width and model identical.
#
# Unlike bootstrap.sh, which checks for dependencies and dies when one is
# missing, this script INSTALLS them. That is the whole point: a teammate should
# not have to read a dependency list, and every missing piece they hit by hand is
# a chance to install the wrong one.
#
# Idempotent. Re-running it is the supported way to repair a half-finished setup.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# ------------------------------------------------------------------ args ----

ASSUME_YES=0
SNAPSHOT=""
DO_INDEX=1
MCP_DIRS=()

while (( $# )); do
  case "$1" in
    --yes|-y)      ASSUME_YES=1; shift ;;
    --snapshot)    SNAPSHOT="${2:-}"; shift 2 ;;
    --snapshot=*)  SNAPSHOT="${1#--snapshot=}"; shift ;;
    --no-index)    DO_INDEX=0; shift ;;
    -h|--help)     sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)            echo "unknown flag: $1" >&2; exit 1 ;;
    *)             MCP_DIRS+=("$1"); shift ;;
  esac
done
export ASSUME_YES

# --------------------------------------------------------- config guard ----

# Deliberately BEFORE sourcing common.sh, whose load_conf would die with
# "run scripts/init.sh first" — advice that is actively wrong here. A teammate
# whose clone has no brain.conf has a stale checkout, not an uninitialised brain,
# and running init.sh would make them the author of a second, conflicting config.
BRAIN_DIR_GUESS="$(cd "$HERE/.." && pwd -P)"
if [[ ! -f "$BRAIN_DIR_GUESS/brain.conf" ]]; then
  cat >&2 <<EOF
 ERR no brain.conf in $BRAIN_DIR_GUESS

    setup.sh configures a brain that someone has ALREADY defined; the settings
    arrive with the repo. Nothing here is yours to choose.

    If you are a teammate:  git pull   (brain.conf is committed — you are behind)
    If you own this brain:  ./scripts/init.sh   (writes brain.conf, once)
EOF
  exit 1
fi

# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
load_conf

echo
log "Setting up '$BRAIN_ID'"
info "embedder      $EMBED_MODEL / ${EMBED_DIMS}d ($EMBED_PROFILE)"
info "reranker      $RERANKER"
info "postgres      $PG_HOST:$PG_PORT $([[ "$PG_MANAGED" == "1" ]] && echo '(this brain owns it)' || echo '(external)')"

# ------------------------------------------------------------ platform ----

OS="$(uname -s)"

# Installing a package manager is not something to do behind someone's back: it
# writes outside this repo, wants sudo, and on a managed laptop may be against
# policy. Everything else here is a package; Homebrew is a decision.
brew_ready() {
  command -v brew >/dev/null 2>&1 && return 0
  local p
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$p" ]] && { eval "$("$p" shellenv)"; return 0; }
  done
  return 1
}

MISSING_MANUAL=()

install_hint() {
  MISSING_MANUAL+=("$1")
  warn "$1"
}

# brew_need <command> <formula> [description]
# Installs only what is actually absent, so a re-run is quiet.
brew_need() {
  local cmd="$1" formula="$2" desc="${3:-$2}"
  command -v "$cmd" >/dev/null 2>&1 && { dim "$desc"; return 0; }

  if [[ "$OS" != "Darwin" ]]; then
    install_hint "$desc is missing. Install it, then re-run: $cmd not found"
    return 1
  fi
  if ! brew_ready; then
    install_hint "$desc is missing and Homebrew is not installed"
    return 1
  fi
  info "installing $desc"
  if brew install "$formula"; then
    ok "$desc"
  else
    install_hint "brew install $formula failed — install $desc by hand"
    return 1
  fi
}

log "Dependencies"

if [[ "$OS" == "Darwin" ]] && ! brew_ready; then
  warn "Homebrew is not installed, and it is how everything below gets installed."
  warn "Install it once with the command from https://brew.sh, then re-run this script:"
  warn '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  die "Homebrew required"
fi
if [[ "$OS" != "Darwin" ]]; then
  warn "automatic installation is implemented for macOS only."
  warn "On Debian/Ubuntu the equivalents are:"
  warn "  curl -fsSL https://bun.sh/install | bash"
  warn "  apt install postgresql-17 postgresql-17-pgvector"
  warn "  curl -fsSL https://ollama.com/install.sh | sh"
  warn "Missing pieces are reported below rather than installed."
fi

command -v git  >/dev/null 2>&1 || install_hint "git is missing (macOS: xcode-select --install)"
command -v curl >/dev/null 2>&1 || install_hint "curl is missing"

# bun: gbrain itself is installed with it.
brew_need bun oven-sh/bun/bun "bun" || true

# Postgres 17. Keg-only, so the binaries never land on PATH — pg_bin_dir() in
# common.sh knows where to look and nothing here needs to touch PATH.
if [[ "$PG_MANAGED" == "1" ]]; then
  if [[ -x /opt/homebrew/opt/postgresql@17/bin/pg_ctl || -x /usr/local/opt/postgresql@17/bin/pg_ctl ]]; then
    dim "postgresql@17"
  elif [[ "$OS" == "Darwin" ]] && brew_ready; then
    info "installing postgresql@17"
    brew install postgresql@17 || install_hint "brew install postgresql@17 failed"
  else
    install_hint "postgresql@17 is missing"
  fi

  # pgvector is the trap in this list, because "installed" is not a property of
  # the machine — it is a property of one Postgres SERVER. Homebrew's formula
  # builds against whichever postgresql versions it knows about, and where the
  # files land does NOT follow from the pg17 prefix: on a current machine the
  # extension sits in /opt/homebrew/share/postgresql@17 while the prefix is
  # /opt/homebrew/opt/postgresql@17. Guessing the path reports a false negative
  # and sends the script off to rebuild something that is already fine.
  #
  # pg_config --sharedir is the authoritative answer, so ask it.
  if [[ "$OS" == "Darwin" ]] && brew_ready; then
    PG_CONFIG_BIN="$(pg_bin_dir)/pg_config"
    vector_control_path() {
      local share
      share="$("$PG_CONFIG_BIN" --sharedir 2>/dev/null || echo '')"
      [[ -n "$share" ]] && printf '%s/extension/vector.control' "$share"
    }
    VECTOR_CONTROL="$(vector_control_path)"
    if [[ -n "$VECTOR_CONTROL" && -f "$VECTOR_CONTROL" ]]; then
      dim "pgvector (postgresql@17)"
    else
      info "installing pgvector"
      brew install pgvector >/dev/null 2>&1 || true
      VECTOR_CONTROL="$(vector_control_path)"
      if [[ -n "$VECTOR_CONTROL" && -f "$VECTOR_CONTROL" ]]; then
        ok "pgvector (postgresql@17)"
      else
        # The formula built against a different server. Rebuilding with
        # PG_CONFIG pointed at 17 is the documented way out.
        warn "pgvector did not install for postgresql@17 — rebuilding from source"
        PG_CONFIG="$PG_CONFIG_BIN" brew install --build-from-source pgvector \
          || install_hint "could not build pgvector for postgresql@17"
      fi
    fi
  fi
fi

# Ollama: the local embedder. Needed at index time AND on every search.
if [[ "$EMBED_PROFILE" == "local" ]]; then
  brew_need ollama ollama "ollama" || true
  if command -v ollama >/dev/null 2>&1; then
    ollama_ensure_running
    ok "ollama running at $OLLAMA_HOST_URL"
  fi
fi

# llama.cpp: the local reranker's server.
if [[ "$RERANKER" == "local" ]]; then
  brew_need llama-server llama.cpp "llama.cpp" || true
fi

# Claude Code is optional — a brain is useful without it, and a teammate may
# drive it from another MCP client entirely.
if ! command -v claude >/dev/null 2>&1; then
  dim "claude CLI not found — MCP registration will be skipped"
fi

if (( ${#MISSING_MANUAL[@]} )); then
  echo
  die "install the missing dependencies above, then re-run this script"
fi

# ----------------------------------------------------------------- .env ----

# The ONLY thing a teammate is ever asked for. A fully local profile asks for
# nothing at all; a private manifest asks for a GitHub token and nothing else.
log "Secrets"

ENV_FILE="$BRAIN_DIR/.env"
env_has() { [[ -f "$ENV_FILE" ]] && grep -q "^${1}=" "$ENV_FILE"; }

env_ask() {
  local var="$1" why="$2" reply
  [[ -n "${!var:-}" ]] && { dim "$var (from environment)"; return 0; }
  env_has "$var" && { dim "$var (in .env)"; return 0; }

  if (( ASSUME_YES )); then
    warn "$var is unset and --yes was passed — skipping. $why"
    return 0
  fi
  echo
  info "$why"
  read -r -s -p "    $var (paste, or Enter to skip): " reply
  echo
  [[ -z "$reply" ]] && { warn "skipped $var"; return 0; }
  ( umask 077; printf '%s=%s\n' "$var" "$reply" >> "$ENV_FILE" )
  chmod 600 "$ENV_FILE"
  ok "$var written to .env"
  export "$var=$reply"
}

# A manifest of private GitHub repos cannot be cloned by a container or a fresh
# laptop without credentials. `gh auth token` prints one if they already use gh.
if grep -q 'github\.com' "$MANIFEST" 2>/dev/null; then
  if [[ -z "${GITHUB_TOKEN:-}" ]] && ! env_has GITHUB_TOKEN; then
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
      [[ -n "$GITHUB_TOKEN" ]] && { export GITHUB_TOKEN; ok "GITHUB_TOKEN from gh auth"; }
    fi
  fi
  env_ask GITHUB_TOKEN "sources.manifest points at github.com. If any repo is private, a token with 'repo' read access is needed to clone it."
fi

if [[ "$EMBED_PROFILE" == "hosted" ]]; then
  case "$EMBED_MODEL" in
    voyage:*)        env_ask VOYAGE_API_KEY     "the hosted embedder ($EMBED_MODEL) needs this key at index AND search time" ;;
    zeroentropyai:*) env_ask ZEROENTROPY_API_KEY "the hosted embedder ($EMBED_MODEL) needs this key at index AND search time" ;;
    openai:*)        env_ask OPENAI_API_KEY     "the hosted embedder ($EMBED_MODEL) needs this key at index AND search time" ;;
  esac
fi
if [[ "$RERANKER" == "hosted" ]]; then
  env_ask "${RERANK_KEY_VAR:-OPENROUTER_API_KEY}" "the hosted reranker needs its own key — an embedding key does not cover it"
fi
if [[ "$EMBED_PROFILE" == "local" && "$RERANKER" != "hosted" ]]; then
  ok "nothing to ask — this brain is fully local"
fi

# Re-load so anything just written to .env is visible to bootstrap below.
load_conf

# ------------------------------------------------------------ bootstrap ----

# bootstrap.sh owns everything that is not dependency installation: the gbrain
# pin, the cluster, the database, the clones, source registration, the Ollama
# model pull and the reranker GGUF download.
echo
"$HERE/bootstrap.sh"

# ------------------------------------------------- local reranker wiring ----

# serve.sh starts llama-server, but starting it is not the same as using it:
# gbrain only calls a reranker when search.reranker.* points at one. Without
# these three keys the process runs, burns memory, and never receives a request
# — and verify.sh reports the reranker as disabled with no hint why.
if [[ "$RERANKER" == "local" ]]; then
  log "Local reranker wiring"
  RR_ALIAS="${RERANK_MODEL_FILE%.gguf}"
  RR_BASE="http://127.0.0.1:$RERANK_PORT/v1"
  if gbrain config set search.reranker.enabled true >/dev/null 2>&1 \
     && gbrain config set search.reranker.model "llama-server-reranker:$RR_ALIAS" >/dev/null 2>&1 \
     && gbrain config set provider_base_urls.llama-server-reranker "$RR_BASE" >/dev/null 2>&1; then
    ok "llama-server-reranker:$RR_ALIAS -> $RR_BASE"
  else
    warn "could not write search.reranker.* — check 'gbrain config show'"
    warn "Search still works; it falls back to hybrid RRF order."
  fi
fi

# ---------------------------------------------------------------- index ----

if (( DO_INDEX )); then
  if [[ -n "$SNAPSHOT" ]]; then
    log "Restoring snapshot"
    [[ -f "$SNAPSHOT" ]] || die "no such snapshot file: $SNAPSHOT"
    if [[ -x "$HERE/snapshot.sh" ]]; then
      "$HERE/snapshot.sh" restore "$SNAPSHOT"
    else
      die "scripts/snapshot.sh does not exist yet — re-run without --snapshot to index from scratch"
    fi
    # A snapshot is a point in time; the repos have moved since it was taken.
    log "Catching up to HEAD"
    "$HERE/refresh.sh" || warn "refresh reported problems — see above"
  else
    echo
    warn "Indexing from scratch. On a multi-repo brain this is tens of minutes."
    warn "If a teammate already published a snapshot, Ctrl-C and re-run with:"
    warn "  ./scripts/setup.sh --snapshot <file>"
    echo
    "$HERE/refresh.sh" || warn "refresh reported problems — see above"
  fi
fi

# ------------------------------------------------------------------ mcp ----

# A brain nobody's agent can reach is a brain nobody uses, and the person most
# likely to stop here is the one who has never seen this repo before. So when no
# directory was passed, ask — rather than printing a next step and exiting.
#
# Skipped without a prompt when: dirs came in as arguments, the run is
# unattended, or Claude Code is not installed (the registration would fail and
# the question would be noise).
if (( ${#MCP_DIRS[@]} == 0 )) && (( ASSUME_YES == 0 )) && [[ -t 0 ]] \
   && command -v claude >/dev/null 2>&1; then
  echo
  log "Connect this brain to your projects"
  cat <<'TXT'
    Registering a directory lets Claude Code search this brain while you work
    there. It is per-directory on purpose — nothing leaks into other projects.

    Give the directories you actually code in, separated by spaces.
    Empty just skips it; ./scripts/register-mcp.sh <dir>... does the same later.
TXT

  # The brain usually lives inside the workspace it describes, so the parent is
  # a better first guess than nothing. Only offered when it looks like a real
  # working directory rather than $HOME or a bare container.
  suggestion=""
  parent="$(dirname "$BRAIN_DIR")"
  if [[ "$parent" != "$HOME" && "$parent" != "/" && -d "$parent" ]]; then
    suggestion="$parent"
    info "suggestion: $suggestion"
  fi

  read -r -p "    Directories [${suggestion}]: " reply || reply=""
  reply="${reply:-$suggestion}"

  for dir in $reply; do
    # Expand a leading ~ by hand: this arrives as literal text from `read`,
    # so the shell never gets the chance to do it.
    [[ "$dir" == "~"* ]] && dir="${HOME}${dir#\~}"
    if [[ -d "$dir" ]]; then
      MCP_DIRS+=("$dir")
    else
      warn "not a directory, skipping: $dir"
    fi
  done
fi

if (( ${#MCP_DIRS[@]} )); then
  echo
  if command -v claude >/dev/null 2>&1; then
    "$HERE/register-mcp.sh" "${MCP_DIRS[@]}"
  else
    warn "claude CLI not found — skipped registering: ${MCP_DIRS[*]}"
    warn "Install Claude Code, then: ./scripts/register-mcp.sh ${MCP_DIRS[*]}"
  fi
fi

# --------------------------------------------------------------- verify ----

echo
log "Verifying"
if "$HERE/verify.sh"; then
  echo
  ok "'$BRAIN_ID' is ready."
  (( ${#MCP_DIRS[@]} )) || info "Expose it to an agent: ./scripts/register-mcp.sh <project-dir>..."
  info "Keep it current:    ./scripts/refresh.sh"
  echo
else
  echo
  warn "setup finished but verify.sh reported failures — read them above."
  warn "Most are repairable by re-running this script; the rest are in docs/TRAPS.md."
  exit 1
fi
