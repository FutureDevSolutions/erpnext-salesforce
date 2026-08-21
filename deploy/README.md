# Production deployment

Builds this fork into a single container image and runs it as a full ERPNext
stack against **external, managed MariaDB and Redis**.

## Quick start

```bash
cp deploy/.env.example deploy/.env      # then fill it in
deploy/deploy.sh                        # preflight -> build -> up
```

`deploy.sh` is the pipeline: it guarantees a usable database, builds the image,
then brings the stack up. Flags: `--skip-build`, `--no-provision`.

To run the steps by hand instead:

```bash
deploy/preflight-db.sh
docker build -t erpnext-salesforce:latest .
docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env up -d
```

## Database preflight

`deploy/preflight-db.sh` runs first and probes `DB_HOST:DB_PORT` **from inside
Docker** — the app containers' point of view, not the host's.

| Probe result | What happens |
|---|---|
| Reachable, credentials work | Nothing. Idempotent, safe to re-run. |
| Nothing listening | Provisions MariaDB on `DB_PORT` with the tuning below. |
| Answers but rejects the credentials | Your database is **left untouched**. A separate instance is created on the next free port, and `DB_PORT` is rewritten in `.env`. |
| Rejects credentials *and* it is our own `mariadb` service | Hard failure with instructions — see below. |

When it provisions, it rewrites `DB_HOST=mariadb`, `DB_PORT`, and
`DB_VOLUME_NAME` in `.env`, keeping a `.env.bak`. Pass `--no-provision` to fail
instead of creating anything — use that in CI against a managed database, where
silently standing up a local DB would hide a real outage.

The provisioned server listens on `DB_PORT` internally *and* publishes the same
number on the host, so `DB_HOST:DB_PORT` means one thing in both places.

**The one case it refuses to fix:** if the rejecting database is this stack's
own `mariadb` service, a new instance would not help — MariaDB fixes the root
password when the data directory is first initialised, so the *volume* is what
rejects you, not the port. The script stops and tells you to restore the old
password, `ALTER USER`, or drop the volume.

### MariaDB settings used when provisioning

Required by Frappe — site creation fails without them:

| Setting | Why |
|---|---|
| `character-set-server=utf8mb4` | Frappe stores 4-byte UTF-8 (emoji, CJK). |
| `collation-server=utf8mb4_unicode_ci` | Matches what Frappe creates tables with. |
| `skip-character-set-client-handshake` | Forces utf8mb4 even when an older client library announces something narrower. |

Recommended, and tunable from `.env`:

| Setting | Default | Why |
|---|---|---|
| `innodb-file-per-table` | on | Frappe makes a table per DocType; keeps them individually reclaimable and gives DYNAMIC row format, which its long indexes need. |
| `max-allowed-packet` | 256M | Backup restores and large fixtures exceed the 16M default. |
| `innodb-buffer-pool-size` | `DB_BUFFER_POOL_SIZE`, 1G | The main performance knob — aim for ~70% of the DB's RAM. |
| `innodb-flush-log-at-trx-commit` | 1 | Full durability per commit. |
| `max-connections` | `DB_MAX_CONNECTIONS`, 200 | Each gunicorn thread and worker holds one. |

Everything runs from the repository root — the build context is the repo.

## What I need from you

Fill these into `deploy/.env`; the rest have working defaults.

| Variable | Why |
|---|---|
| `SITE_NAME` | Must equal the domain users browse to. Frappe routes on it. |
| `DB_HOST` | Managed MariaDB 10.6+, configured for utf8mb4. Leave empty to have one provisioned for you. |
| `DB_ROOT_PASSWORD` | Creates the site's own DB and user — and the server itself, if the preflight provisions one. |
| `REDIS_CACHE`, `REDIS_QUEUE` | Two logical instances, or one server with different DB indexes. |
| `ADMIN_PASSWORD` | Initial Administrator password. |
| `ENCRYPTION_KEY` | `python3 -c "import secrets; print(secrets.token_urlsafe(32))"` |
| SMTP (optional) | `MAIL_SERVER`, `MAIL_PORT`, `MAIL_LOGIN`, `MAIL_PASSWORD`, `MAIL_FROM` |

Your managed MariaDB must be started with utf8mb4 defaults, or site creation
fails on collation:

```
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
skip-character-set-client-handshake
```

## Architecture

One image, six roles. The role is the container's command.

| Service | Command | Notes |
|---|---|---|
| `create-site` | `create-site.sh` | One-shot. Creates the site, then `bench migrate` on later deploys. Everything waits on it. |
| `backend` | `gunicorn` | WSGI, gthread workers. |
| `websocket` | `websocket` | `node apps/frappe/socketio.js`. |
| `queue-short` | `worker` | `short,default` queues — interactive work. |
| `queue-long` | `worker` | `long` queue, so slow reports cannot starve the above. |
| `scheduler` | `scheduler` | **Exactly one replica** — two would double-enqueue every cron job. |
| `frontend` | `nginx` | Serves assets and `/files`, proxies the rest. Publishes `HTTP_PORT`. |

One image rather than separate backend/frontend images because the backend
reads `sites/assets/*.json` to render content-hashed asset URLs that nginx then
has to serve. Splitting them invites a manifest/asset mismatch on every deploy.

Put your TLS terminator in front of `frontend`. It sets
`X-Forwarded-Proto`-aware redirects, so Frappe generates `https://` URLs when
the edge terminates TLS.

## Why `python:3.14-slim` and not `node:alpine`

Alpine 3.24 does ship Python 3.14, so the version pin was never the problem.
musl is. Three dependencies publish no musl wheels:

| Package | On Alpine |
|---|---|
| `duckdb` 1.4.3 | compiles DuckDB's C++ from source |
| `typst` 0.15.0 | needs a Rust toolchain |
| `mysqlclient` 2.2.8 | sdist-only everywhere; one small C build |

On Debian slim only `mysqlclient` compiles, and only in the builder stage.
Alpine would have saved ~130MB of base OS — the rest of the 3.79GB dev image is
two pyenv Pythons, two nvm Nodes, `build-essential`, LLVM, every `-dev` header,
and both PDF engines. Multi-stage removes those regardless of base.

## Operations

```bash
# logs
docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env logs -f backend

# a bench command against the live site
docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env \
  exec backend bench --site "$SITE_NAME" console

# deploy a new build: create-site re-runs and migrates before traffic resumes
docker build -t erpnext-salesforce:latest .
docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env up -d
```

### Backups

There is deliberately no backup service here — with a managed database you
should be using its snapshot/PITR features, not `bench backup` into a container
volume. What the volumes hold that the database does not is
`sites/<site>/public/files` and `private/files`; back those up, or move them to
S3 with Frappe's built-in file storage settings.

## Building for another architecture

The image is arch-agnostic but a plain `docker build` produces only your host's
architecture. For an amd64 host from an Apple Silicon machine:

```bash
docker buildx build --platform linux/amd64 -t erpnext-salesforce:latest --load .
```

Cross-building under emulation is slow; a native amd64 CI runner is much faster.

## Pin before you ship

`FRAPPE_BRANCH` defaults to `develop` because erpnext 17.0.0-dev requires
frappe >=17.0.0-dev. `develop` is a moving target — two builds a week apart are
not the same image. Pin it to a tag or SHA before any real release:

```bash
docker build --build-arg FRAPPE_BRANCH=<sha> -t erpnext-salesforce:1.0.0 .
```

## Rebuild gotchas

Three things cost me time; they are commented in the Dockerfile too.

1. **`bench build` does not run `yarn install`.** That normally happens inside
   `bench get-app`, which this Dockerfile bypasses in favour of copying the repo
   in. Without `bench setup requirements --node` the build fails on
   `Could not resolve "onscan.js"` — and `bench build` still **exits 0** on that
   failure, so trust the log text, not the exit code. The same applies to
   `docker build ... | tail`: the pipeline reports `tail`'s status, not Docker's.
   Redirect to a file instead.
2. **Never add `--hard-link` to `bench build`.** `frappe/build.py` puts the
   node_modules link at `sites/assets/<app>/node_modules`. Normally
   `sites/assets/<app>` is a symlink into `apps/<app>/<app>/public`, so that
   link lands *inside the app* — which is exactly where `desk.bundle.scss`'s
   `@import "frappe/public/node_modules/highlight.js/..."` resolves it.
   `--hard-link` turns `sites/assets/<app>` into a real directory, the link
   lands there instead, and the build dies on `Could not resolve`. The symlinks
   it writes are absolute, so moving `sites/assets` aside is safe anyway.
3. **`.dockerignore` is load-bearing.** `.git` alone is 1.7GB. Without it the
   build context is ~2.2GB instead of ~155MB.
