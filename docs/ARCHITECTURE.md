# Architecture

Why the template is shaped the way it is. Read this before changing it.

## The index is a cache; git is the truth

Everything in `sources/`, `db/` and `.gbrain/` is derived. Delete all three and
`bootstrap.sh` + `refresh.sh` rebuild them from `sources.manifest`. That is why
they are gitignored and why backups are barely a topic: there is nothing there
to lose.

The exceptions are `inbox/` and, on a server, `notes/<person>/`. Those are
written by people and agents and exist nowhere else, which is exactly why they
are plain markdown inside the git repository rather than rows in the database.
Committing them **is** the backup.

This split is also why a code source must never be written to. A `put_page`
into an imported repository lands in a directory that the next sync overwrites
from git. It looks like it worked and it is gone by morning.

## One directory is one brain

The repository is the root, and the derived directories are its gitignored
children. Teardown is `pg_ctl stop` plus `rm -rf`.

The mechanism that makes several brains coexist is `GBRAIN_HOME`. gbrain
appends `.gbrain` to it, so exporting `GBRAIN_HOME=<brain-dir>` in
`scripts/lib/common.sh` moves the entire config surface — connection string,
audit log, locks — inside the brain. Without it, gbrain reads `~/.gbrain` and a
machine gets exactly one brain, which is the limitation this template exists to
remove.

Every script sources `common.sh`, so the isolation is not something a caller
can forget. This is also why `scripts/serve.sh` is what you register with an
MCP client and never bare `gbrain serve`: the wrapper is where `GBRAIN_HOME` is
set.

Each brain also gets its own Postgres cluster on its own port, picked by
`init.sh` from the first free one. A cluster costs ~40 MB of overhead, which is
a fair price for a teardown that cannot orphan another brain's data.

What is genuinely shared: the reranker GGUF (~640 MB, cached once in
`~/.cache/gbrain/models`), the reranker process, Ollama, and gbrain itself.
The first three are stateless. **gbrain is not** — `bun install -g` means one
version per machine, so the pin in `brain.conf` is a declaration, not an
enforcement. `verify.sh` reports drift; nothing prevents it.

## Everything about a source lives in the manifest

`sources.manifest` holds id, URL, branch and strategy. `bootstrap.sh`
reconciles reality to it — clone what is missing, re-point what moved, register
what is unregistered — and is idempotent, so the workflow for any change is
"edit the manifest, re-run bootstrap".

Strategy has to live there because **there is nowhere else to put it**.
`sources add` has no `--strategy` flag, and `sync` reads
`source.config.strategy` which no CLI command writes. So `refresh.sh` loops
per source and passes `--strategy` explicitly. `sync --all` would be shorter
and would silently drop the strategy, reducing a code brain to whatever `.md`
files happen to lie around while reporting success.

The branch column encodes a policy: index the **integration** branch. The index
is a shared artifact describing how the system works, and feature branches
churn. Agents read local files for the working tree; they read the brain for
the system.

## One repository, two branches

The id — not the URL — names the clone directory and the gbrain source, so the
same repository can appear twice under two ids on two branches. That is how you
index a live contract version alongside the one still in production:

```
orders-v2	git@github.com:acme/orders.git	main		code
orders-v1	git@github.com:acme/orders.git	release/v1	code	isolated
```

Two separate clones, two sources, refreshed independently. `manifest_rows`
rejects a duplicate id, because two rows sharing one would share a clone
directory and each bootstrap would flip its branch back and forth.

What this does **not** do is keep the older version out of results. Both
versions are genuinely relevant to a question about "the orders contract", and
measurement confirmed the federation flag does not filter them out either (see
`docs/TRAPS.md`). The mechanisms that actually work are an explicit `source_id`
when the version is known, version-bearing ids so every result announces which
branch it came from, and a corpus whose own file headers say which version they
are.

## Exclusions are a git feature, not a gbrain feature

gbrain has no native exclude mechanism, so `sparse-excludes` is applied with
`git sparse-checkout --no-cone`: the file leaves the clone's working tree while
staying in the git index, and gbrain's walker skips `ls-files` entries that are
missing on disk.

Two consequences worth remembering. Excluded content is genuinely absent, so
this is a real boundary for secrets and not merely a ranking hint. And every
rule for a source must be applied in one `sparse-checkout set` call, because
that command *replaces* the rule set — `bootstrap.sh` groups by source id
before calling it.

## The inbox uses import, not sync

`gbrain sync` requires its source path to be the **root** of a git repository.
The inbox is a subdirectory of this one, so sync fails on it with a misleading
"not a git repository". `gbrain import` walks a directory directly and honours
`GBRAIN_SOURCE`, so that is what the scripts use.

The trade-off: import has no notion of deletion. Removing a note file leaves
its page in the index until you `gbrain delete` the slug.

## Verification tests the door agents actually use

`verify.sh` exists because this system's failures are silent. A half-loaded
reranker returns "No results" rather than an error. An untrusted stdio
transport returns `[]` for cross-source queries. A wrong-strategy sync reports
success. In all three cases the brain answers — with less than it has — and the
conclusion you draw is that the knowledge base is mediocre.

So the retrieval check speaks real JSON-RPC to `gbrain serve` over stdio
(`scripts/lib/mcp-probe.sh`) instead of shelling out to the CLI. This is not
pedantry: `gbrain call` sets `remote: false` in `cli.ts` and therefore runs the
trusted path, which is precisely the path agents do not use. Testing through
the CLI proves nothing about what an agent sees.

Similarly, the reranker check issues a real `/v1/rerank` request rather than
hitting `/health`, because `/health` returns ok before the model has loaded.

## The one-way door

The embedding model determines the vector width, and the width is baked into
the database schema. Changing it later means re-embedding everything.

Two things follow. Choose before the first index. And notice that above 2000
dimensions pgvector cannot build an HNSW index at all, so the free local
2560-dimension model leaves you on exact scan — correct, roughly 100 ms against
~18k chunks, and O(n). That is fine for one person and wrong for a team, which
is why server mode wants a 1024–1536 dimension hosted model.

## Server mode is the same repository

`PG_MANAGED=0` tells `common.sh` that Postgres belongs to somebody else — a
container, a managed service — so it waits for the port instead of running
`pg_ctl`. `PG_HOST` and `PG_PASSWORD` come from the environment. Nothing else
about the scripts changes, and `verify.sh` runs unmodified inside the container.

Access control is two independent axes, both enforced in SQL: `--source` for
write authority, `--federated-read` for read scope. The limit to design around
is that **reads are source-granular**. Slug-prefix binding fences writes, not
visibility, so anything that must be invisible to someone has to be its own
source.
