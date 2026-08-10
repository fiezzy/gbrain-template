# The gbrain runtime for server mode: the CLI, git (to pull the index clones),
# and a Postgres client (so the brain's own scripts can talk to the db
# container). Postgres itself is a separate service — see docker-compose.yml.

FROM oven/bun:1-debian

# Global bun installs land under BUN_INSTALL. Putting it in /usr/local rather
# than /root means the binary stays readable when the container runs as a
# non-root user, which it does — see `user:` in docker-compose.yml.
ENV BUN_INSTALL=/usr/local

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates openssh-client postgresql-client \
    && rm -rf /var/lib/apt/lists/*

ARG GBRAIN_PIN=v0.42.73.2
RUN bun install -g "github:garrytan/gbrain#${GBRAIN_PIN}" \
    && gbrain --version

# Private repositories are cloned over SSH with a read-only deploy key mounted
# at /keys. accept-new trusts a host's key on first contact but still fails if
# it ever changes — the right trade-off for an unattended clone.
ENV GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/brain/db/known_hosts -i /keys/id_deploy"

# The brain directory is bind-mounted here by compose.
WORKDIR /brain
ENV GBRAIN_HOME=/brain
ENV PG_MANAGED=0

CMD ["gbrain", "serve", "--http", "--port", "3131"]
