# portfolio

Household portfolio tracker — holdings, statement imports, price history. Everything behind a
Google sign-in gate, with an allowlist of exactly the people who may enter.

- **URL:** https://portfolio.<your-domain>
- **VM / static IP:** portfolio / 10.1.1.10
- **Upstream:** https://github.com/chethan123/portfolio — the app, its image, and the compose
  file this package was migrated from. Read its `docs/operating.md` before touching the database.
- **Requires Docker Engine 28.0+** on the VM. Not a preference — see Notes.

## Deploy

```bash
# on the app VM (sparse-checkout this app dir)
docker --version                         # must be 28.0 or newer, see Notes

mkdir -p volumes/db/data volumes/dumps    # create_host_path:false — `up` fails naming these
chown "$(id -u):$(id -g)" volumes/dumps   # must match DUMP_UID/DUMP_GID below

cp allowed-emails.example.txt secrets/allowed-emails.txt   # who may sign in, one address a line
cp .env.example .env                      # then fill in: BASE_DOMAIN, POSTGRES_PASSWORD,
                                          # GATE_CLIENT_ID/SECRET, GATE_COOKIE_SECRET,
                                          # DUMP_UID=$(id -u), DUMP_GID=$(id -g)
docker compose up -d
```

Before the first `up`, register a Google OAuth client (upstream `docs/google-sign-in.md`). Its
redirect URI must be exactly `https://portfolio.<your-domain>/oauth2/callback` — the gate compares
it character-for-character, and so does the app's passkey relying-party id (upstream ADR-0012).
Changing the subdomain later means re-registering the client and re-enrolling every passkey.

Then, on each Global Caddy VM, once the route is pulled:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## Upgrade

```bash
docker compose up -d     # pull_policy:always re-pulls the floating major tag
```

`APP_VERSION` unset floats with every `v1.x.y`. Pin it in `.env` to hold still or roll back.

## Notes

- **Egress:** `gate` reaches Google, `egress-proxy` reaches five Yahoo hosts through a CONNECT
  tunnel with a pinned ClientHello. **`app` has none** — no default route, no resolver. `worker`
  has none of its own either; `egress-proxy` is its only way out.

- **Docker 28.0+ is load-bearing.** Engine 26 ignores `gateway_mode_ipv4: isolated` silently and
  27 refuses it. Without it every container on an `internal` network still gets a host route,
  which is most of the isolation this stack is built on. On 26 the stack comes up looking healthy
  and quietly isn't.

- **Hardening deviations** (all recorded with reasons in `app.meta.yaml`):
  - Service is `app`, not the slug, and there are seven networks rather than
    `edge`/`frontend`/`backend`. Both keep upstream's `scripts/smoke-test.sh` runnable — it
    asserts this stack's isolation and keys on those exact names. The seven are strictly tighter
    than the house three, not looser.
  - `secrets_mode: env`, not the house `hybrid`. Every credential is interpolated `${VAR:?}`, so
    `up` refuses and names the variable rather than starting half-protected. A file-secret for
    `POSTGRES_PASSWORD` would cover `db` while the same value still sat in `app`'s and `dump`'s
    environment.
  - Two floating image tags, both argued in `app.meta.yaml`: the app's (it *is* the upgrade
    mechanism) and Postgres's (the anchor keeps `db` and `dump` matched, which is what matters).
  - `mem_limit`/`cpus`/`pids_limit` on `db`, `dump`, `app`, `gate` and `caddy` are **starting
    values this migration added** — upstream sets them on `worker` and `egress-proxy` only. The
    caps, tmpfs and `read_only` posture is upstream's measured result and is asserted by its
    smoke test; the limits are not. `/harden-container` has never run against this app.

- **`scripts/dump-loop.sh` is vendored** from the upstream repo — the `dump` service bind-mounts
  it, and a VM checks out `apps/portfolio/` and nothing else. **Re-vendor it when upstream
  changes it.** Same for `docker-compose.yml` and `Caddyfile`, which were adapted rather than
  copied; `app.meta.yaml` lists every edit.

- **The allowlist lives in `secrets/`,** not beside the compose file as upstream has it — real
  addresses, and `**/secrets/*` is what this repo's `.gitignore` covers. Restart `gate` after
  editing it: a single-file bind mount stops following a file replaced by rename.

- **Backups:** `volumes/db/data` is the database; `volumes/dumps` holds the nightly `pg_dump`
  (`DUMP_KEEP_DAYS=7` by default). The dumps are a hand-off window for whatever collects them,
  not your history — snapshot them off the VM. They are every balance and every uploaded
  statement in plaintext, written 0640 in a 0750 directory.

- **Not vendored:** upstream's `compose.dev.yaml`, `compose.test.yaml`, `compose.external-db.yaml`
  and `scripts/smoke-test.sh`. Run those from an upstream checkout against upstream's own
  `compose.yaml`, not this package.
