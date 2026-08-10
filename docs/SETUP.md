# Local setup

From an empty directory to a brain your agents query. Budget an hour, most of
it waiting on the first index.

## 0. Prerequisites

```bash
# macOS
brew install bun git postgresql@17 pgvector llama.cpp
# and Ollama, if you want the free local embedder: https://ollama.com
```

`bootstrap.sh` checks every one of these before it changes anything, and tells
you exactly what is missing.

## 1. Clone and name it

```bash
git clone <this-template> acme-brain
cd acme-brain
./scripts/init.sh
```

`init.sh` asks four things and writes three files. It touches nothing outside
the directory.

**Brain id** — lowercase, `[a-z0-9-]`. Becomes the database name and the MCP
server name your agents see.

**Embedding provider.** The one-way door. The vector width is baked into the
schema; changing it later means re-embedding everything.

| | dimensions | cost | HNSW index | good for |
|---|---|---|---|---|
| `local` — Ollama | 2560 | free | **no** (over pgvector's 2000 ceiling) | one person, one laptop |
| `voyage:voyage-code-3` | 1024 | $0.18/1M, first 200M free | yes | code; the server |
| `zeroentropyai` | 1280 | $0.05/1M | yes | cheapest hosted |
| `openai:text-embedding-3-large` | 1536 | $0.13/1M | yes | you already have the key |

Concretely: a 12-repo codebase is roughly 3.5M tokens, so a **full** index
costs well under a dollar on any hosted provider, and incremental refreshes
cost cents. The reason to choose hosted is rarely money — it is the HNSW index
and not having to run a 4GB model. The reason to choose local is that nothing
leaves your machine.

**Reranker** — `local` runs a small cross-encoder on llama-server, free, and
noticeably improves precision. `none` works fine; hybrid retrieval carries it.

**Repositories** — one line each, `<git-url> [branch] [strategy]`.

## 2. The manifest

`init.sh` seeds `sources.manifest`; edit it directly from then on. Tab
separated, four columns:

```
acme-api	git@github.com:acme/api.git	main	code
acme-web	git@github.com:acme/web.git	dev	code
acme-docs	git@github.com:acme/docs.git	main	markdown
```

**Strategy** is `code` (source files — enables `code_def` / `code_refs` symbol
lookup), `markdown` (`.md`/`.mdx` only), or `auto` (both).

**Branch policy: index the integration branch** — the branch work lands on.
`main`, `dev`, whatever your team merges into. Never a feature branch, never a
worktree. The index is a shared artifact and feature branches churn; index the
branch their work lands on, and the brain stays a stable description of the
system.

Adding a repo later is one line plus `./scripts/bootstrap.sh`. Changing a
branch is one edit plus `bootstrap.sh` — it re-points the existing clone
correctly, which involves a subtlety it handles for you (see `docs/TRAPS.md`).

## 3. Exclusions

`init.sh` pre-seeds `sparse-excludes` with lock files for every source. Add to
it whatever is bulk without signal:

```
acme-web	src/locales
acme-web	public/assets/generated
acme-api	src/fixtures/cities.json
```

Worth excluding: locale and i18n dictionaries (thousands of near-identical
strings that dilute every search), vendored or minified bundles, generated API
clients, large JSON fixtures, and anything with secrets.

The mechanism is `git sparse-checkout` rather than a gbrain setting, because
gbrain has no native exclude. Excluded paths are physically absent from the
clone, so the indexer cannot see them.

## 4. Build it

```bash
./scripts/bootstrap.sh     # installs gbrain, creates the cluster + brain,
                           # clones and registers every source
./scripts/refresh.sh       # the actual indexing
```

The first `refresh.sh` is the slow part. Hosted embedding is bounded by the
provider's rate limits — tens of minutes for a mid-size project. Local Ollama
is bounded by your GPU: hours, not minutes.

Re-running either script is safe. `bootstrap.sh` reconciles; `refresh.sh` is
incremental after the first pass.

## 5. Verify

```bash
./scripts/verify.sh
```

Not a formality. It checks the things that fail **silently**: whether every
chunk actually got embedded, whether a vector index exists, whether the
reranker is genuinely loaded (its `/health` lies during model load), whether
excluded paths really left the clones, whether anything secret-looking got
indexed, and — most importantly — whether a real MCP stdio session can retrieve
across sources.

That last check is the one that matters. If it fails, agents get empty answers
with no error, and you will blame the model. Read `docs/TRAPS.md`.

## 6. Hand it to your agents

```bash
./scripts/register-mcp.sh ~/work/acme-api ~/work/acme-web
```

Then paste `docs/AGENT-POLICY.md` into each project's `CLAUDE.md`. Do not skip
this: without the `source_id: "__all__"` rule, agents scope every query to the
notes and report that the brain is empty.

## Keeping it current

```bash
./scripts/refresh.sh
```

Pulls every clone, re-syncs, sweeps deferred embeddings, extracts links. Run it
when you notice the brain is behind, or put it on a schedule:

```bash
# every weekday at 08:00
0 8 * * 1-5  cd /path/to/acme-brain && ./scripts/refresh.sh >> db/refresh.log 2>&1
```

On the server this is a systemd timer — see `deploy/README.md`.

## Removing a brain

```bash
"$(brew --prefix postgresql@17)/bin/pg_ctl" -D /path/to/acme-brain/db/pg stop
rm -rf /path/to/acme-brain
```

That is the whole teardown. Nothing lives outside the directory except the
shared model cache in `~/.cache/gbrain/models`, which other brains use too.
