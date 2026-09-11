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

mkdir -p volumes/db/data volumes/dumps          # both binds refuse to create themselves; `up`
                                                # fails naming them
id -u; id -g                                    # note both numbers — you type them in below

cp allowed-emails.example.txt secrets/allowed-emails.txt   # who may sign in, one address a line
cp .env.example .env
```

Then edit `.env` and set: `BASE_DOMAIN`, `POSTGRES_PASSWORD`, `GATE_CLIENT_ID`,
`GATE_CLIENT_SECRET`, `GATE_COOKIE_SECRET`, and `DUMP_UID`/`DUMP_GID` — as the **literal numbers**
`id` printed. A `.env` is not a shell: `DUMP_UID=$(id -u)` is stored verbatim and the container
fails to create. Then:

```bash
docker compose up -d
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

- **Backups:** `volumes/db/data` is the database; `volumes/dumps` holds the nightly `pg_dump`
  (`DUMP_KEEP_DAYS=7` by default). The dumps are a hand-off window for whatever collects them,
  not your history — snapshot them off the VM. They are every balance and every uploaded
  statement in plaintext; the script writes them 0640 (`umask 027`) but never touches the
  directory's own mode, so `chmod 0750 volumes/dumps` after creating it is on you.

- **Not vendored:** upstream's `compose.dev.yaml`, `compose.test.yaml`, `compose.external-db.yaml`
  and `scripts/smoke-test.sh`. The smoke test cannot run against this package under any
  circumstances — it hardcodes `COMPOSE_FILE=compose.yaml:compose.dev.yaml` and `up --build`,
  needing a Dockerfile and source tree that are not here. Run it from an upstream checkout
  against upstream's own `compose.yaml`.
