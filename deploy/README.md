# Server deployment

One host runs the brain. Your team's agents query it over MCP with OAuth, and
install nothing.

```
  teammates: Claude Code · Cursor · Claude Desktop
        │  HTTPS · MCP · OAuth 2.1
        ▼
   caddy — automatic TLS
        │
   gbrain serve --http
     ├─ /mcp     agents
     └─ /admin   dashboard: clients, scopes, live request log
        │
   postgres 17 + pgvector
        │
   sources/ — the index clones
        ▲
   systemd timer → refresh.sh
```

> **Untested path.** Everything here is derived from gbrain's own deployment
> documentation and its source, and the local half of the template is verified.
> The server half has not been run against a real host yet. Treat the first
> deployment as a shakedown, not a routine.

## What it costs

Sizing is driven by corpus size, not by team size — a query is a few hundred
milliseconds of CPU, so a handful of people barely register. Roughly 750 tokens
and ~50 KB of database per source file, measured on a real 12-repo brain.

| project | files | database | one-off full index | host | €/month |
|---|---|---|---|---|---|
| 1–3 repos | ~1 000 | ~50 MB | $0.04–0.14 | 2 vCPU / 4 GB | ~6 |
| 5–15 repos | ~5 000 | ~250 MB | $0.19–0.68 | 4 vCPU / 8 GB | ~9 |
| 30+ repos | ~25 000 | ~1.2 GB | $0.94–3.40 | 4 vCPU / 8 GB | ~9 |
| large monorepo | ~100 000 | ~5 GB | $3.75–13.50 | 8 vCPU / 16 GB | ~16 |

The index column is a **full re-index from scratch**; incremental refreshes
cost cents. The range spans ZeroEntropy ($0.05/1M) to Voyage ($0.18/1M), and
Voyage's first 200M tokens are free per account, which covers the first three
rows outright.

Embedding spend is noise next to the host. Add ~€0.50 for an IPv4 and ~€1 for
the domain.

**Do not run the local Ollama profile on the server.** It needs ~8 GB of RAM
for the model alone and, without a GPU, turns a first index into an overnight
job. The only reason to accept that is a hard rule against sending code to a
third party — with a hosted embedder, chunks are transmitted at index time.

## Rehearse it locally first

Before touching a VPS, run the whole stack on your own machine. Same images,
same scripts, same code paths — minus TLS, which needs a real domain.

```bash
cd deploy
cp .env.example .env          # DOMAIN can stay fake; PG_PASSWORD anything
                              # HOST_UID/GID: echo "$(id -u) $(id -g)"

L="-f docker-compose.yml -f docker-compose.local.yml"

docker compose $L --profile tools run --rm bootstrap
docker compose $L --profile tools run --rm refresh
docker compose $L up -d db gbrain

open http://localhost:3131/admin      # bootstrap token is in the gbrain logs
```

Name `db gbrain` explicitly on `up`. Caddy stays out of a local run: it would
try to obtain a certificate for a domain that does not resolve here and restart
in a loop.

### Three levels of fidelity

**1 — free.** The override points the container at the Ollama already running
on your host, so with `EMBED_PROFILE=local` a rehearsal costs nothing. It
exercises the image build, the pinned gbrain inside it, the external-Postgres
path, container-to-container networking, `bootstrap.sh` and `refresh.sh`
running as a non-root user against the bind-mounted checkout, the HTTP server
binding and answering, the admin dashboard, and OAuth client registration.

The database it produces is **not** interchangeable with the server's: the
local model's vector width differs. This rehearses mechanics only.

**2 — the real embedder.** Set `brain.conf` to the hosted profile and put the
provider key in `deploy/.env`. Ollama is then never touched. Nothing else about
the commands changes.

This is worth more than the fidelity: the vector width now matches production,
so the rehearsal database **is** a production database. Dump it over and the
server skips its first index entirely.

```bash
docker compose $L exec db pg_dump -U brain acme_brain | gzip > brain.sql.gz
# on the server, before starting anything:
gunzip -c brain.sql.gz | docker compose exec -T db psql -U brain acme_brain
```

**3 — plus a tunnel.** The last two things localhost cannot give you are a real
certificate and an OAuth handshake against a public issuer URL. A tunnel
supplies both:

```bash
cloudflared tunnel --url http://localhost:3131      # or: ngrok http 3131
PUBLIC_URL=https://<what-it-printed> docker compose $L up -d db gbrain
```

`--public-url` has to match what clients actually hit, or OAuth discovery
advertises the wrong issuer and every client fails at the handshake — which is
why it is a variable rather than a constant.

Now hand a teammate a real `claude mcp add` line against that URL. If it works
there, the only remaining difference from production is which machine it runs
on, and caddy in place of the tunnel.

## Prerequisites

1. A host with Docker and the compose plugin.
2. A domain whose A record points at it, with **ports 80 and 443 open**. Caddy
   needs :80 for the ACME challenge; opening only :443 leaves you with no
   certificate and a confusing failure.
3. A read-only deploy key for each private repository.
4. An API key for the embedding provider.

## Deploy

```bash
# on the server
sudo mkdir -p /srv && sudo chown "$USER" /srv
git clone <your-brain-repo> /srv/acme-brain
cd /srv/acme-brain

# The embedder is the one thing the environment cannot override, because the
# vector width is baked into the schema. It must already say `hosted`; if the
# brain was initialized locally against Ollama, re-run scripts/init.sh --force
# on a fresh checkout rather than editing a live database's width.
grep EMBED_ brain.conf

# Everything else — host, port, credentials, PG_MANAGED — comes from compose's
# environment, which brain.conf defers to. Nothing to edit here.
cd deploy
cp .env.example .env
$EDITOR .env              # DOMAIN, PG_PASSWORD, HOST_UID/GID, provider key

mkdir -p keys && cp ~/deploy_key keys/id_deploy && chmod 600 keys/id_deploy

docker compose build

# ONCE: create the brain, clone the repos, register the sources.
# `refresh` assumes all of this already exists, so it cannot come first.
docker compose run --rm bootstrap

# Then the index. This is the long step.
docker compose run --rm refresh

# Now bring the server up.
docker compose up -d
docker compose logs -f gbrain      # note the admin bootstrap token on first boot
```

Verify from inside the container:

```bash
docker compose exec gbrain /brain/scripts/verify.sh
```

`verify.sh` checks the things that fail silently — embedding coverage, whether
a vector index exists, whether cross-source retrieval actually works through a
real MCP session. Do not skip it because the logs look clean.

## Keep it current

```bash
sudo cp systemd/gbrain-refresh.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gbrain-refresh@acme.timer
systemctl list-timers gbrain-refresh@acme
```

The unit is templated on the brain name and expects the checkout at
`/srv/<name>-brain`; adjust `WorkingDirectory` if yours lives elsewhere.

**Why a timer rather than CI or webhooks.** An incremental refresh over
unchanged repositories costs seconds — a `git pull` that fast-forwards nothing
and a sync that finds no diff. At that price, running it every 15 minutes buys
freshness far more cheaply than any push-based plumbing, and it has properties
the alternatives do not: one place to configure, no credential in any pipeline,
no coupling between the brain and anybody's build, and it catches up on its own
after downtime.

Putting an indexing step in each repository's CI is the option to avoid. CI
cannot index — `sync_brain` is `localOnly` and refused over HTTP — so a
pipeline can only *signal* the server. You would be maintaining N pipelines and
N credentials to send a message that a webhook sends for free, while making the
brain a dependency of every build: fail the job when the brain is down and you
block merges, ignore the failure and indexing silently stops.

**If you do want push-driven updates**, gbrain has them natively — no pipeline
code, configured in the repository's settings:

```bash
docker compose exec gbrain gbrain sources webhook set api-v5 --github-repo acme/api
docker compose --profile webhooks up -d      # the queue worker, see below
```

Point the repository's webhook at `https://<domain>/webhooks/github` with the
printed secret. Two things to know before you rely on it:

- **One repository maps to exactly one source.** The lookup is
  `WHERE config->>'github_repo' = $1 LIMIT 1`, so with `api-v4` and `api-v5`
  both pointing at `acme/api` only one of them can be reached; pushes to the
  other branch answer `202 ignored` and never sync.
- **The webhook enqueues, it does not sync.** Without `gbrain jobs work`
  running the job never executes. That is the `webhooks` compose profile.

Upstream's own guidance, which this template follows, is to treat webhooks as a
latency optimisation layered on top of a scheduled refresh — never as the only
mechanism, because a push that lands while the server is down is simply lost.

### Driving the brain from its own repository

`.github/workflows/brain.yml` turns this repository into the control plane. It
SSHes to the server and runs `deploy/scripts/apply.sh`, which pulls the repo
first and then acts on what it finds.

The valuable trigger is **push**. Because the manifest lives here, adding a
repository to the index becomes an ordinary pull request:

```
  edit sources.manifest  →  push  →  workflow  →  ssh  →  apply.sh apply
                                                            ├ git pull
                                                            ├ bootstrap  (clone, register, exclusions)
                                                            └ refresh    (index)
```

The manifest stays the single source of truth, and pushing it is what applies
it. A reviewer sees exactly what will be indexed, in a diff, before it happens.

Set four repository secrets: `BRAIN_SSH_KEY`, `BRAIN_SSH_HOST`,
`BRAIN_SSH_USER`, `BRAIN_DIR`. Give the key its own account on the server — it
can run docker there.

`workflow_dispatch` adds a Run-workflow button with `refresh` / `apply` /
`verify`, which is a pleasant way to hand teammates a safe manual re-index and
to keep the logs somewhere they can read them.

**Do not make the workflow's `schedule` your only heartbeat.** GitHub's cron is
best-effort: runs are routinely delayed, dropped under load, and scheduled
workflows are disabled outright in a repository with no activity for 60 days.
The cron in the file is offset off the hour for that reason, but the guarantee
still belongs to the systemd timer. Use the workflow for applying changes, for
on-demand runs, and for visibility; keep the timer for freshness.

Both are safe to run at once: `apply.sh` takes a non-blocking `flock`, so
whichever arrives second exits immediately instead of queueing.

**One sharp edge.** `apply.sh` pulls with `--ff-only` and stops if the server's
checkout has diverged. That happens when notes written by agents get committed
on the server and never pushed. Decide early who owns pushing `inbox/` and
`notes/` — those files are the only content here that cannot be rebuilt.

## Give people access

```bash
cd /srv/acme-brain/deploy
./scripts/grant-access.sh ivan
```

That registers an OAuth client, creates a personal notes source so nobody's
writes land on anyone else's, and prints the one command Ivan runs on his own
machine:

```bash
claude mcp add acme -t http https://brain.acme.example/mcp \
  --client-id ... --client-secret ...
```

**Nothing is installed on his side.** No gbrain, no database, no models, no
clones — Claude Code speaks HTTP MCP natively, so the client is Claude Code
itself. The same endpoint works for Cursor, Claude Desktop and ChatGPT (the
latter needs the OAuth 2.1 + PKCE flow, which `serve --http` provides).

Only the server needs gbrain installed, and only you administer it.

### Bearer token or OAuth client?

`gbrain auth create <name>` mints a bearer token, which is simpler:

```bash
claude mcp add acme -t http https://brain.acme.example/mcp \
  -H "Authorization: Bearer gbrain_xxx"
```

But a bearer token is **long-lived and full-access** — it grandfathers to
`read+write+admin` and carries no source scoping at all. It also lands in the
holder's `~/.claude.json` in plain text. Use it for your own machine or a
throwaway; use OAuth clients for anyone else, because scoping only exists
there.

### What remote clients cannot do

Four operations are `localOnly` and refused over HTTP regardless of scope:
`sync_brain`, `file_upload`, `file_list`, `file_url`. Remote agents get no
filesystem surface. Indexing stays a server-side job — which is what the
systemd timer is for.

Scoping:

```bash
./scripts/grant-access.sh ivan --read acme-api,acme-web   # only these sources
./scripts/grant-access.sh ci --read-only                  # no write authority
./scripts/grant-access.sh --revoke ivan
```

Change someone's scope later without reissuing anyone's secret:

```bash
docker compose exec gbrain gbrain auth rescope-client <client_id> \
  --federated-read acme-api,acme-web,shared
```

### The one limitation to understand

Two axes, both enforced in SQL: `--source` decides where a person may **write**,
`--federated-read` decides what they may **read**.

**Reads are source-granular and nothing finer.** Slug-prefix binding fences
writes, not visibility. So a repository that must be invisible to someone has
to be its own source, left out of their read list. There is no way to hide part
of a source, and building an access model that assumes otherwise will leak.

## Operating notes

**Secrets.** `.env` and `keys/` are gitignored. The database has no `ports:`
entry and is reachable only on the compose network — keep it that way.

**The admin dashboard** at `https://<domain>/admin` shows registered clients,
their scopes, and a live request feed. Its bootstrap token is printed to stderr
on first boot, or pre-set it with `ADMIN_BOOTSTRAP_TOKEN` in `.env`. Request
parameters are redacted by default; leave them redacted on a shared brain.

**Backups.** The database is a derived cache — rebuildable from git plus
`sources.manifest`. The parts that are *not* rebuildable are `inbox/` and any
`notes/<person>/` directories, and those are plain markdown in your git
repository. So the real backup is committing and pushing them:

```bash
cd /srv/acme-brain && git add inbox notes && git commit -m "notes" && git push
```

A database dump only saves you re-indexing time:

```bash
docker compose exec db pg_dump -U brain acme_brain | gzip > backup.sql.gz
```

**Upgrading gbrain.** Change `GBRAIN_PIN` in both `.env` and `brain.conf`, then
`docker compose up -d --build`. Run `verify.sh` afterwards — and read the
upstream changelog first, because several past releases changed whether
migrations, embedding failures, or dry-runs behaved as documented.
