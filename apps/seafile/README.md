# seafile

Seafile Community Edition 13 — file sync & share (Dropbox-alike) with desktop and mobile clients,
versioned libraries, and optional client-side encrypted libraries.

- **URL:** https://files.<your-domain>
- **VM / static IP:** seafile / 10.1.1.8 — 8 GB RAM, 4 vCPU
- **Upstream:** https://manual.seafile.com/13.0/setup/setup_ce_by_docker/

**Core-only deployment.** Four containers: sidecar Caddy, seafile, MariaDB, Redis. SeaDoc,
the notification server, Seafile AI, face recognition, OnlyOffice and Collabora are all off.
See `components_disabled` in `app.meta.yaml` — any of them can be added later without data
migration, but each brings new sidecar routes (the upstream route table is transcribed into the
comments in `./Caddyfile`).

## Deploy

The first boot is **two phases**. Do not skip to phase 2 — read "Non-root bring-up" below for why.

```bash
# On the seafile VM (sparse-checked-out):
cp .env.example .env
chmod 600 .env
# Fill in SEAFILE_SERVER_HOSTNAME, generate each credential:
#   openssl rand -base64 24   -> SEAFILE_MYSQL_DB_PASSWORD, REDIS_PASSWORD,
#                                INIT_SEAFILE_MYSQL_ROOT_PASSWORD, INIT_SEAFILE_ADMIN_PASSWORD
#   openssl rand -hex 32      -> JWT_PRIVATE_KEY (>= 32 chars)
# Leave NON_ROOT=false for now.

# --- phase 1: initialise as root ---
docker compose up -d
docker compose logs -f seafile        # wait for "seafile server is running now."

# --- phase 2: drop to uid 8000 ---
docker compose down
sudo chown -R 8000:8000 volumes/seafile
sed -i 's/^NON_ROOT=false/NON_ROOT=true/' .env
docker compose up -d
```

Then log in at `https://files.<your-domain>` with `INIT_SEAFILE_ADMIN_EMAIL` /
`INIT_SEAFILE_ADMIN_PASSWORD` and **immediately do the post-install config** below.

### Non-root bring-up — why two phases

`NON_ROOT=true` on a *fresh* volume does work in one shot, but it is the worse outcome. From the
image's own scripts:

- `scripts_13.0/enterpoint.sh` gates on the data directory: it aborts unless `/shared/seafile/` is
  either mode `777` **or** owned by `seafile`. The check is `[[ $permissions != "777" && $owner !=
  "seafile" ]]` — either condition satisfies it.
- `scripts_13.0/bootstrap.py:166` runs an unconditional `chmod -R a+rwx /shared/` when
  `NON_ROOT=true` — but only inside `init_seafile_server()`, which **returns early** once
  `seafile-data/` already exists.

So: initialise once as root (normal ownership), then `chown -R 8000:8000`. The permission gate
passes on *owner*, initialisation is skipped, and the `chmod -R a+rwx` never runs. Go straight to
`NON_ROOT=true` instead and your entire library ends up world-writable — which is what upstream's
own instructions (`chmod -R a+rwx /opt/seafile-data/`) leave you with.

The container is not given a compose `user:` key, deliberately. It must start as root so `my_init`
can supervise nginx/syslog-ng/cron and `enterpoint.sh` can `useradd` uid 8000; `start.py` then
launches the actual servers with `su seafile -c ...`. An external `user:` breaks that bootstrap.

**Consequence for maintenance:** in-container scripts must be run as the seafile user, e.g.
`docker compose exec seafile su seafile -c "/opt/seafile/seafile-server-latest/seaf-gc.sh"`.

### Post-install config (required)

`bootstrap.py` computes the site's scheme and hostname and then **discards them** — it never writes
`SERVICE_URL` or `CSRF_TRUSTED_ORIGINS`. Seahub falls back to deriving its public URL from request
headers. The sidecar asserts `X-Forwarded-Proto: https` (see `./Caddyfile`), which covers most of
it, but pin it explicitly so nothing depends on header handling:

```bash
# Append to volumes/seafile/seafile/conf/seahub_settings.py, then: docker compose restart seafile
SERVICE_URL = 'https://files.<your-domain>'
FILE_SERVER_ROOT = 'https://files.<your-domain>/seafhttp'
CSRF_TRUSTED_ORIGINS = ['https://files.<your-domain>']
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
```

Skipping this is the classic failure mode: the site loads, but logging in returns a bare **403**
(Django 5 CSRF origin check) and every share link comes out `http://`.

### Optional: retire the first-boot values

`INIT_SEAFILE_MYSQL_ROOT_PASSWORD` and `INIT_SEAFILE_ADMIN_PASSWORD` are read only on first boot —
MariaDB ignores its root password once `/var/lib/mysql` exists, and `start.py` deletes
`conf/admin.txt` immediately after creating the admin account. Once you have logged in
successfully you can blank both in `.env` and `docker compose up -d`, taking them off disk. Keep a
copy of the MariaDB root password in your password manager first — you will want it for manual
DB maintenance, and re-initialising from empty volumes needs both again.

## Notes

- **Egress: none.** `needs_egress: false` — `seafile` sits on `frontend` + `backend`, both
  `internal: true`. Verified rather than assumed: the CE 13.0 Dockerfile bakes in the server
  binaries and every pip dependency at build time, and none of `enterpoint.sh`, `start.py`,
  `bootstrap.py`, `setup-seafile-mysql.py` or `upgrade.py` make an outbound call. The container
  cannot reach the internet *or* the LAN.
- **No email, as a result.** No password-reset mail, no share-link notifications, no invites, no
  admin alerts. An admin can set any user's password from the web admin panel, and share links
  still work — they just get copy-pasted by hand. `.env.example` documents the exact two-step flip
  (add `edge` to the seafile service's networks, then configure SMTP in `seahub_settings.py`) if
  you decide you want it; update `needs_egress` in `app.meta.yaml` at the same time.
- **Hardening deviations:** `read_only: false` on the seafile container. It is a phusion baseimage
  — runit creates `supervise/` dirs in place under `/etc/service/*`, which cannot be tmpfs-mounted
  without masking the run scripts, and `enterpoint.sh` rewrites `/etc/passwd`, `/var/spool/cron`
  and several files under `/scripts` on every boot. MariaDB and Redis are both `read_only: true`.
  All capability sets are **unverified starting positions** — `hardening_verified: false` in
  `app.meta.yaml` until `/harden-container` has run.
- **Upstream's proxy is not used.** Their `caddy.yml` runs `lucaslorentz/caddy-docker-proxy` with
  `/var/run/docker.sock` bind-mounted, which this repo forbids. The sidecar Caddy replaces it.
- **Backups:** `volumes/` holds all state — snapshot/tar it. Two parts that must be consistent with
  each other: `volumes/db` (MariaDB — the metadata, sharing, and user tables) and
  `volumes/seafile/seafile/seafile-data` (the content-addressed block store). A block store
  without its database is unreadable. Stop the stack, or dump the DB with `mysqldump` while the
  block store is quiescent. `volumes/seafile/seafile/conf` holds `seahub_settings.py` — small, but
  losing it means redoing the post-install config above.
- **Storage is all local**, no NFS. Seafile's block store is many small chunks with commit/fs
  metadata alongside; the house NFS options are `soft`, which returns an I/O error mid-write when
  the NAS blips. Recoverable via `seaf-fsck` rather than fatal, but not worth the churn.
- **Redis holds no state** — `--save "" --appendonly no`. Losing it loses nothing but a cache.

## Upgrading

Bump the tag in `docker-compose.yml` (currently `seafileltd/seafile-mc:13.0.25`), then
`docker compose up -d`. `start.py` runs `check_upgrade()` on boot and applies schema migrations
automatically. Back up `volumes/db` first; minor-version upgrades within 13.0 are routine, major
version jumps are not — read the upstream upgrade notes and never skip a major.
