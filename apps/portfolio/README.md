# portfolio

Household portfolio tracker — holdings, statement imports, price history. Everything behind a
Google sign-in gate, with an allowlist of exactly the people who may enter.

- **URL:** https://portfolio.<your-domain>
- **VM / static IP:** portfolio / 10.1.1.10
- **Published port:** `:80` on the Sidecar Caddy, and nothing else.
- **Upstream:** https://github.com/chethan123/portfolio — the app, its image, and the compose
  file this package was migrated from (at v2.0.3). Read its `docs/operating.md` before touching
  the database.
- **Requires Docker Engine 28.0+** on the VM. Not a preference — see Notes.

## Before the first deploy

Register a Google OAuth client (upstream `docs/google-sign-in.md`). Its redirect URI must be
exactly `https://portfolio.<your-domain>/oauth2/callback` — the gate compares it
character-for-character, and so does the app's passkey relying-party id (upstream ADR-0012).
Changing the subdomain later means re-registering the client and re-enrolling every passkey.
You need its client ID and secret to fill in `.env` below.

## Deploy

Run this as the **non-root** account that will own the dumps. `scripts/dump-loop.sh` refuses to
run as root, and because nothing `depends_on` the `dump` service, a root deploy crash-loops it
silently while the rest of the stack goes green.

```bash
# on the app VM (sparse-checkout this app dir)
docker version --format '{{.Server.Version}}'   # must be 28.0+ — the SERVER, not `docker --version`

mkdir -p volumes/db/data volumes/dumps volumes/backup-cache   # binds refuse to create themselves;
chmod 0750 volumes/dumps                                       # `up` fails naming them
id -u; id -g                                    # note both numbers — you type them in below

cp allowed-emails.example.txt secrets/allowed-emails.txt   # who may sign in, one address a line
cp .env.example .env
```

Then edit `.env` and set: `BASE_DOMAIN`, `POSTGRES_PASSWORD`, `GATE_CLIENT_ID`,
`GATE_CLIENT_SECRET`, `GATE_COOKIE_SECRET`, `BACKUP_PING_URL` (below), and `DUMP_UID`/`DUMP_GID`
— as the **literal numbers** `id` printed. A `.env` is not a shell: `DUMP_UID=$(id -u)` is
stored verbatim and the container fails to create.

Backups (`docker-compose.backup.yml`; `docs/specs/backup-sidecar.md` §6) need four file-secrets,
three htpasswd lines on restic-server, and an Uptime Kuma monitor:

```bash
openssl rand -hex 32 > secrets/restic-password    # the repository password. ESCROW IT (password
                                                  # manager): it cannot rescue itself from a backup
for t in nfs rsync-net pcloud; do                 # one REST login per target, username = slug
  printf 'RESTIC_REST_USERNAME=portfolio\nRESTIC_REST_PASSWORD=%s\n' "$(openssl rand -hex 24)" > secrets/backup-$t.env
done
chmod 0400 secrets/restic-password secrets/backup-*.env
```

On restic-server, append a `portfolio` bcrypt line — the password from each `backup-<target>.env`
— to that target's htpasswd file and restart the three backends (its README, "Onboarding a new
app"). In Uptime Kuma, add a **push** monitor (heartbeat 24 h + grace), and put its push URL in
`.env` as `BACKUP_PING_URL`. Then:

```bash
docker compose up -d                              # both files — COMPOSE_FILE in .env
docker compose run --rm --name backup-run backup run   # first backup by hand; the monitor should go up
```

Finally, on each Global Caddy VM once the route is pulled:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## Upgrade

```bash
docker compose up -d     # pull_policy:always re-pulls the floating major tag
```

`APP_VERSION` unset floats with every `v2.x.y`. Pin it in `.env` to hold still or roll back. The
tag never crosses a major — going to v3 means setting `APP_VERSION=3` deliberately, after reading
upstream's release notes.

## Restoring

```bash
docker compose run --rm --name backup-snapshots backup -n nfs snapshots       # or -n rsync-net, -n pcloud
mkdir restore && docker compose run --rm --name backup-restore -v ./restore:/restore \
  backup -n nfs restore latest --target /restore
```

`--name` for the same reason as `dump verify` below: `container_name: backup` is fixed and the
scheduled container holds it.

`restore/dumps/` then holds the archives, owned by `DUMP_UID`; `dump verify` (below) checks one,
and upstream's `docs/operating.md` says how to load it. `restore/secrets/` and `restore/env/.env`
are this stack's credentials — treat the directory accordingly and delete it when done.

## Verifying a dump

```bash
docker compose run --rm --name dump-verify dump verify /dumps/<file>
```

`--name` is required here and not upstream: this package sets `container_name: dump` per house
convention, and a bare `compose run` would reuse it and collide with the running loop container.

## Notes

- **Networks (seven, upstream's):**

  | network | internal | members | purpose |
  |---|---|---|---|
  | `ingress` | no | caddy | the one published port (house `edge`) |
  | `caddy-app` | yes | caddy, app | sidecar ⇄ app (house `frontend`) |
  | `backend` | yes | app, dump, db | app/dump ⇄ db (house `backend`) |
  | `caddy-gate` | yes | caddy, gate | held apart from `caddy-app` so `app` has no route to `gate:4180` |
  | `worker-proxy` | yes | worker, egress-proxy | no gateway at all — worker can't reach the host's ports |
  | `egress-proxy` | no | egress-proxy | the CONNECT tunnel out to five Yahoo hosts |
  | `egress-gate` | no | gate | out to Google |

- **Egress:** `gate` reaches Google, `egress-proxy` reaches five Yahoo hosts. **`app` has none** —
  no default route, no resolver. `worker` has none of its own either; `egress-proxy` is its only
  way out. (`app.meta.yaml` records `needs_egress: true` on restic-server's reading — *some*
  service here holds egress, not the app service.)

- **Docker 28.0+ is load-bearing.** Engine 26 ignores `gateway_mode_ipv4: isolated` silently and
  27 refuses it. Without it every container on an `internal` network still gets a host route,
  which is most of the isolation above. On 26 the stack comes up looking healthy and quietly
  isn't — which is why the check above reads the server version, not the CLI's.

- **Hardening deviations** (all recorded with reasons in `app.meta.yaml`):
  - `gate` runs as **root** — the image sets no `USER`, and pinning one would decide the
    allowlist's file mode for you. It carries `DAC_READ_SEARCH` for exactly that file. The
    sidecar carries `NET_BIND_SERVICE`, not to bind (8080 needs nothing) but because
    `/usr/bin/caddy` has `cap_net_bind_service=ep` set and needs it in the bounding set to exec.
  - `app`, `worker` and `egress-proxy` carry no `user:`; identity comes from the image's
    `USER node`. Worth pinning — `price-worker-sock` already hardcodes uid 1000.
  - Service is `app`, not the slug, and there are seven networks rather than
    `edge`/`frontend`/`backend`. The seven are strictly tighter than the house three; keeping
    upstream's *names* for them, and `app`, only buys a clean diff when re-vendoring.
  - `secrets_mode: env`, not the house `hybrid`. Every credential is interpolated `${VAR:?}`, so
    `up` refuses and names the variable rather than starting half-protected.
  - Two floating image tags, both argued in `app.meta.yaml`: the app's (it *is* the upgrade
    mechanism) and Postgres's (the anchor keeps `db` and `dump` matched, which is what matters).
  - `mem_limit`/`cpus`/`pids_limit` on `db`, `dump`, `app`, `gate` and `caddy` are **starting
    values this migration added**. Upstream bounded only `worker` and `egress-proxy`, and even
    there set no `cpus`. `/harden-container` has never run against this app and nothing in this
    package has been executed — `hardening_verified: false`.

- **`scripts/dump-loop.sh` is vendored** from the upstream repo — the `dump` service bind-mounts
  it, and a VM checks out `apps/portfolio/` and nothing else. **Re-vendor it when upstream
  changes it.** `docker-compose.yml` and `Caddyfile` were adapted rather than copied;
  `app.meta.yaml`'s `upstream_edits` is the list to replay.

- **The allowlist lives in `secrets/`,** not beside the compose file as upstream (and upstream's
  `operating.md`) has it — real addresses, and `**/secrets/*` is what this repo's `.gitignore`
  covers. A stray copy at the package root is separately gitignored so following upstream's
  habit can't commit it. Restart `gate` after editing: a single-file bind mount stops following
  a file replaced by rename.

- **Backups** — the reference implementation of ADR-0006 (`docs/specs/backup-sidecar.md`).
  `docker-compose.backup.yml` adds the `backup` sidecar, running as the dump account on its own
  `backup-egress` network, pushing at 03:00 UTC to all three restic-server targets. The backup set
  is exactly what it binds under `/backup`: `volumes/dumps` (the database, as the 02:00 verified
  `pg_dump` archives — `DUMP_KEEP_DAYS=7` is a hand-off window; history is the repositories),
  `secrets/` and `.env` (every credential of this stack, encrypted at rest — spec D9: the
  repository password must therefore live somewhere else too, and a rotated secret stays in old
  snapshots for the retention window). Not in the set, on purpose: `volumes/db/data` (uid 70,
  0700, never read live), `volumes/caddy`, `volumes/backup-cache`. The dumps are every balance and
  every uploaded statement in plaintext; the script writes them 0640 (`umask 027`) but never
  touches the directory's own mode, so `chmod 0750 volumes/dumps` after creating it is on you.
  One Uptime Kuma push per run (`status=up`, or `down` naming the failed targets); there is no
  other monitoring. `.env` is a single-file bind, like the allowlist: after editing it,
  `docker compose up -d --force-recreate backup`. **Not yet run on a VM** — the sidecar joins
  `hardening_verified: false`.

- **Not vendored:** upstream's `compose.dev.yaml`, `compose.test.yaml`, `compose.external-db.yaml`
  and `scripts/smoke-test.sh`. The smoke test cannot run against this package under any
  circumstances — it hardcodes `COMPOSE_FILE=compose.yaml:compose.dev.yaml` and `up --build`,
  needing a Dockerfile and source tree that are not here. Run it from an upstream checkout
  against upstream's own `compose.yaml`.
