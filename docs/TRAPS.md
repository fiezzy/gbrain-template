# Traps

Failures that do not announce themselves. Every entry here was paid for once —
the point of the template is that it is not paid for again.

The pattern is almost always the same: the brain **answers**, it just answers
with less than it has. Nothing errors, nothing logs, and the conclusion you
draw is "the knowledge base isn't very good" rather than "the knowledge base is
misconfigured".

Status is against gbrain **v0.42.73.2**, which is what `brain.conf` pins.

---

## Retrieval

### Cross-source search returns nothing over MCP
**Status: open upstream · detected by `verify.sh` · fix is opt-in**

The stdio MCP transport marks its callers remote/untrusted, deliberately. For
an untrusted caller `source_id: "__all__"` spans only *granted* sources — and a
local stdio agent holds no grants. So every cross-repo query an agent makes
comes back empty, with no error and no warning. The CLI works fine, which makes
this maddening to diagnose: you test by hand, it works, the agent still finds
nothing.

`gbrain call <op>` will not reproduce it either — `cli.ts` sets `remote: false`
for that path. The only honest test is a real MCP stdio session, which is what
`scripts/lib/mcp-probe.sh` does and what `verify.sh` runs.

Upstream PR #2652 flips stdio to trusted. It is open and unmerged; the
maintainer's position is stated in the code comment. A later fix (#3242/#3301)
made federated pages visible to no-grant MCP callers and may have resolved the
symptom on its own — which is exactly why the template **measures instead of
assuming**.

```
./scripts/verify.sh                      # tells you whether you have the problem
./scripts/patch-stdio-trust.sh --status  # detail, changes nothing
./scripts/patch-stdio-trust.sh           # apply, with confirmation and a backup
./scripts/patch-stdio-trust.sh --revert
```

The patch edits the **global** gbrain install, so it affects every brain on the
machine, and a `bun install -g` reverts it silently. Re-run it after any gbrain
upgrade.

### `query` without an explicit source scopes to one source
**Status: by design — this is a policy problem, not a bug**

An unqualified `query` returns hits from the caller's resolved source only.
Since `serve.sh` sets `GBRAIN_SOURCE=inbox` (so that writes land in the
git-backed inbox), an agent that forgets `source_id: "__all__"` searches the
notes and nothing else, then reports that the brain doesn't know.

This is why `docs/AGENT-POLICY.md` states the rule in capitals. Put it in every
`CLAUDE.md`. It is the single highest-leverage line in this whole template.

### A half-loaded reranker returns "No results"
**Status: inherent to llama-server · handled by `serve.sh` and `verify.sh`**

`llama-server`'s `/health` returns ok **before** the model finishes loading.
Queries issued in that window come back empty rather than slow. So neither
`serve.sh` nor `verify.sh` trusts `/health` — both probe with a real
`/v1/rerank` call and check for a `relevance_score` in the reply.

If search goes empty right after a reboot, this is the first thing to check.

### An "isolated" source is not actually hidden
**Status: measured on v0.42.x · the manifest's fifth column is a label, not a filter**

`gbrain sources add --no-federated` is documented as restricting a source to
queries that name it explicitly. Measured behaviour on a two-source brain is
weaker than that: the unfederated source came back in

- `source_id: "__all__"` over MCP — expected, since `__all__` means *span
  everything*, and federation is not consulted;
- an **unqualified** query over MCP, with no `source_id` at all;
- an unqualified `gbrain query` on the CLI, i.e. the trusted local path.

Only an explicit `source_id: "<id>"` scoped correctly, returning that source
alone.

This matters because the agent policy tells agents to always pass
`source_id: "__all__"`, which bypasses federation by definition. So do not
build an access or ranking model on the federation flag. If content must be
out of the way, the reliable options are: leave it out of the manifest, or give
it its own brain (`GBRAIN_HOME` makes that cheap).

### Two versions of one contract compete for the same results
**Status: inherent to retrieval · design around it**

Indexing `release/v1` and `main` of the same repository puts two near-identical
copies of every file in the corpus. Embeddings of `OrderV1` and `OrderV2` are
close together, so a question about "the orders contract" retrieves both, and
half the result budget goes to the version nobody asked about.

Nothing in the tooling can fix this, because it is a genuine ambiguity — the
query really does match both. What works:

- **Distinct, version-bearing ids** (`orders-v1`, `orders-v2`), so the agent can
  see which version each hit came from in the result's `source_id`.
- **Explicit scoping when the version is known**: `source_id: "orders-v2"`.
  This is the only mechanism that reliably narrows retrieval.
- **Make the code say its own version.** A file header of "Orders contract v1 —
  LEGACY, frozen, three partners remain" is worth more than any configuration,
  because it lands in the chunk text and both the reranker and the agent can
  act on it.
- **A separate brain for a frozen version** you rarely query, if the noise
  outweighs the convenience.

### `--no-expand` makes retrieval look much worse than it is
Multi-query expansion is on by default over MCP. Benchmarking with
`--no-expand` on the CLI and concluding the brain is weak compares two
different systems. Judge quality the way agents actually query.

---

## Sync and indexing

### `sync --all` silently drops `--strategy`
**Status: open · worked around by `refresh.sh`**

`gbrain sync --all` ignores `--strategy` and falls back to markdown-only. On a
code brain that means it imports whatever `.md` files happen to be lying around
and reports success. Worse, no CLI command persists a per-source strategy —
`sources add` has no `--strategy` flag, and `sync` reads
`source.config.strategy` which nothing writes.

So the strategy lives in `sources.manifest` and nowhere else, and `refresh.sh`
loops per source applying it explicitly. **Never replace that loop with
`sync --all`.**

### `sync --full` cannot delete stale pages for code sources
**Status: open · `refresh.sh` warns before letting you do it**

`performFullSync`'s delete-reconcile only considers pages with a non-NULL
`pages.source_path`. The code importer never writes that column — it stashes
the path in `frontmatter->>'file'` instead — so every code page has
`source_path IS NULL`, the reconcile matches nothing, and deleted files keep
their pages forever.

Deletions therefore only land through the **incremental** path, from the git
diff's `D` entries. Consequences:

- After a branch switch, run a normal `refresh.sh`. Not `--full`.
- If `git gc` prunes the old branch's commits before that run, gbrain falls
  back to a full re-import and the stale pages survive.

To audit by hand: list the source's pages and drop the ones whose
`frontmatter->>'file'` no longer exists in the clone.

### Switching a manifest branch needs the refspec widened first
**Status: handled by `bootstrap.sh`**

Clones are `--single-branch`, so `origin`'s refspec only fetches the branch
they were cloned with. Change the branch in the manifest without widening it
and the new branch is invisible — `refresh.sh` keeps fast-forwarding the old
one and everything looks fine.

`bootstrap.sh` detects the change, runs `remote set-branches`, fetches,
switches, and tells you to run a normal (not `--full`) refresh.

### GitHub webhooks map one repository to exactly ONE source
**Status: upstream design · fatal for two-branch setups · prefer the timer**

`gbrain serve --http` exposes `POST /webhooks/github`, authenticated per source
by HMAC. It looks the source up with

```sql
SELECT id, config FROM sources WHERE config->>'github_repo' = $1 LIMIT 1
```

`LIMIT 1`. If you index two branches of one repository as `api-v4` and
`api-v5`, both rows carry the same `github_repo`, the lookup returns whichever
one the index happens to yield, and then the pushed ref is compared against
that source's `tracked_branch`. A push to the branch belonging to the *other*
source answers **202 `ignored`, reason `ref_mismatch`** — a green delivery in
GitHub's UI and no sync.

So on a two-version brain, webhooks keep at most one branch per repository
fresh, and fail silently for the rest. The scheduled refresh has no such
limitation: it walks the manifest and treats every source identically.

### A webhook sync needs a worker, or it never runs
**Status: upstream design · the compose stack ships one behind a profile**

The webhook handler does not sync inline. It enqueues a `sync` job on the
Minions queue and returns 202 with a job id. Nothing executes that job unless
`gbrain jobs work` is running somewhere. Without a worker the queue grows, the
index stays stale, and every signal in the chain — GitHub's delivery log, the
HTTP response — reports success.

`docker compose --profile webhooks up -d` starts one. The timer path does not
need it: `refresh.sh` syncs inline.

### Deleted pages stay noisy for 72 hours
Soft-deleted pages remain in the `embed --stale` queue until the purge window
closes. Expect harmless errors about them for three days. The hard delete is
the `purge_deleted_pages` MCP tool or the autopilot purge phase; there is no
CLI for it.

---

## Embeddings

### One enormous file can poison a whole source
**Status: mitigated by `sparse-excludes` · partly fixed in 0.42.69.0**

Generated files — lock files, bundled JSON dictionaries, megastring constants,
locale tables — are simultaneously the least useful content in a repository and
the most likely to break embedding. A single multi-megabyte line is a
reproducible way to take down a local embedding runner.

gbrain has **no native exclude mechanism**, so the template uses
`git sparse-checkout --no-cone`: the file is removed from the clone's working
tree, and gbrain's walker skips `ls-files` entries that are missing on disk.
That is what `sparse-excludes` is.

Since 0.42.69.0 a single bad chunk no longer darkens its entire page, and
`gbrain embed` exits non-zero on genuine failures — which is why `refresh.sh`
collects those failures and reports them at the end instead of dying halfway
through.

### All of a source's exclusions must be applied in one call
**Status: handled by `bootstrap.sh`**

`git sparse-checkout set` **replaces** the rule set. Applying one source's
paths in two batches silently undoes the first batch, and the files you
excluded quietly come back. `bootstrap.sh` groups every rule per source id
before calling it once.

### Changing the embedding model is a full re-index
The vector width is baked into the database schema. Switching provider or model
means `gbrain retrieval-upgrade --to <model> --reindex` and re-embedding
everything. Decide before the first index, not after.

### Above 2000 dimensions there is no vector index at all
pgvector cannot build an HNSW index on columns wider than 2000 dimensions, so a
2560-dimension model (the local Ollama default) leaves you on exact scan. It is
*correct*, and for one person on a laptop it is fine — measured at roughly 100ms
against ~18k chunks. But it is O(n), and it degrades with corpus size and with
concurrent users.

For anything served to a team, pick a model at 1024–1536 dimensions so the
index actually exists. `verify.sh` reports which situation you are in.

---

## Operations

### gbrain is installed globally, so the pin is machine-wide
`bun install -g` means one gbrain per machine, shared by every brain on it.
`brain.conf` records the version this brain expects and `verify.sh` reports
drift, but nothing *enforces* it. Two projects that genuinely need different
gbrain versions will fight.

### `gbrain list` used to cap at 100 rows
**Status: fixed in 0.42.66.0** — `list_pages` now returns what you asked for,
and a truncated listing says so instead of looking complete.

### The dream cycle did nothing on local models
**Status: fixed in 0.42.69.0** — with a cost cap set, any model missing from
the pricing tables hard-failed the first work item, latched a budget flag, and
skipped everything after it while still reporting success. Local providers now
price at $0, so caps stay enforceable and the cycle actually runs. If you pin
an older gbrain and use Ollama, background enrichment is doing nothing.

### Non-ASCII names were shredded during mention extraction
**Status: fixed in 0.42.69.0** — the tokenizer matched ASCII letters and digits
only, so Cyrillic, Vietnamese, and anything with diacritics broke into
fragments that matched nothing. Relevant to any non-English brain.

### `apply-migrations --yes` did not apply
**Status: fixed in 0.42.70.0** — it warned that the schema was behind, then
printed "All migrations up to date" and exited 0. If you have a brain that an
upgrade never healed, this was why.

### `sync --dry-run` was not read-only
**Status: fixed in 0.42.70.0** — a dry run could pull from the remote and
delete indexed pages before reaching its own early-return.
