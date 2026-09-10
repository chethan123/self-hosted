# CLAUDE.md — self-hosted monorepo

Collection of every self-hosted app as a standalone `docker compose` stack, one directory per app,
each deployed to its own Proxmox VM. **Private** GitHub repo. Read `CONTEXT.md` (glossary) and
`docs/adr/` (the *why*) before changing conventions.

## Golden rules (never violate)

1. **Never commit secrets or state.** Real `.env`, `secrets/*`, and `volumes/` are gitignored.
   Only `.env.example` (dummy values), `secrets/.gitkeep`, and code are committed.
2. **Only the Sidecar Caddy (and Global Caddy) publish host ports.** App and db services never
   use `ports:`. A `ports:` on an app/db service is a bug — flag it.
3. **Maximally hardened by default** (ADR-0003). Loosen only per-app, with a recorded reason.
4. **Base domain is parameterized** as `{$BASE_DOMAIN}`; never hardcode the real domain in a
   committed file. Internal RFC1918 IPs may be committed (private repo).
5. **If a secret is ever committed, rotate it first.** History rewriting (`git filter-repo`) is
   cleanup, not the fix. gitleaks pre-commit is the guard (`.pre-commit-config.yaml`).

## Repository layout

```
apps/<name>/         one app package (see apps/_template/ for the canonical shape)
global-caddy/        the shared public reverse proxy; sparse-checked-out to each Caddy VM
docs/adr/            architecture decision records (0001-0005)
CONTEXT.md           domain glossary
.agents/skills/      onboard-app, harden-container
```

Each app VM sparse-checks-out only its own `apps/<name>/`. Caddy VMs sparse-check-out `global-caddy/`.

## Architecture (see ADRs for rationale)

- **Nested Caddy** (ADR-0001): `client --https--> Global Caddy (TLS) --http--> Sidecar Caddy --> app`.
  The Sidecar is the per-app inbound security edge and the only LAN-exposed port on the VM.
- **Routing** (ADR-0002): multiple Global Caddy instances, round-robin DNS, static-IP routing.
  Each app owns `global-caddy/sites/<name>.caddy` — a host-matcher **fragment**
  (`@name host <subdomain>.{$BASE_DOMAIN}` + `handle @name { reverse_proxy <vm_ip>:<port> }`), imported
  *inside* the shared `*.{$BASE_DOMAIN}` block via `import sites/*.caddy` so all apps reuse one
  wildcard cert (ADR-0005). Not a standalone site block — that would issue a per-host cert.
- **TLS** (ADR-0005): wildcard `*.{$BASE_DOMAIN}` cert via DNS-01; subdomain-per-app. Needs a Caddy
  image built with the DNS module (`xcaddy`).
- **Naming**: the app service is named after the app slug — never `app` — because that name is what
  the Sidecar `reverse_proxy`es to (Compose registers the *service* name as the network alias).
  Every service also sets an explicit `container_name:` so `docker ps` reads the same on every VM:
  `caddy-<app>` for the Sidecar, the service name verbatim for everything else. Plain `caddy` is
  reserved for the Global Caddy. `container_name:` is cosmetic — it changes no DNS, but it does
  make the name host-global and rule out `--scale` (fine: one app per VM, nothing is replicated).

## Per-app networks (three, per VM)

| network | type | members | purpose |
|---|---|---|---|
| `edge` | bridge | sidecar (+ app iff `needs_egress`) | published port; egress |
| `frontend` | `internal: true` | sidecar, app | sidecar ⇄ app, no internet |
| `backend` | `internal: true` | app, db | app ⇄ db, no internet; sidecar can't reach db |

App has **no egress unless `needs_egress: true`** (which adds it to `edge`). DB lives on `backend` only.

## Hardening defaults (ADR-0003)

`cap_drop:[ALL]` + minimal `cap_add` · `security_opt:[no-new-privileges:true]` · non-root
(`user:` for vanilla/self-built; **PUID/PGID** for linuxserver.io) · `read_only: true` + sized
`tmpfs` · `pids_limit` / `mem_limit` / `cpus` · pinned image tags · never `privileged`, never the
Docker socket. Discover the minimal caps/tmpfs with the `harden-container` skill; record them in
`app.meta.yaml`.

## Secrets (hybrid)

`env_file: .env` for config and env-only images; Docker **file-secrets** (`*_FILE`, mounted at
`/run/secrets/`) for high-value secrets on images that support it (Postgres, etc.). Every `.env`
key has a placeholder in `.env.example` so `cp .env.example .env && edit && docker compose up` never
misses a variable.

## Data

Co-located `volumes/<service>/` bind mounts, gitignored. `volumes/` holds all app state — back it up.

## NFS volumes (optional)

Apps needing network storage use Docker named volumes with the `local`+`nfs` driver, one per export,
N per app. Standard options: `addr=<server-ip>,rw,soft,timeo=30,retrans=3,intr` — always **`soft`**
(`hard` has caused hangs here). Server is addressed by static IP. The daemon mounts the export `rw`;
**read-only is enforced per-container at the mount** (`:ro` default, `:rw` opt-in) — never in the NFS
options. NFS is mounted by the VM host's kernel and bind-mounted in, so it works regardless of a
service's network isolation (`needs_egress` is unrelated). Declare each in `app.meta.yaml` under
`nfs_volumes` (`name`, `server`, `export`, `mount_path`, `access`); the `access` flag must match the
mount's `:ro`/`:rw` suffix.

## Adding / migrating an app

Use **`/onboard-app`** (`new` or `migrate`). It interviews, scaffolds from `apps/_template/`, writes
`app.meta.yaml` + the global route, then hands off to **`/harden-container`** for the bring-up loop.
Do not hand-scaffold — the skills enforce the invariants above.

## app.meta.yaml

The machine-readable per-app contract (routing + hardening decisions). Keep it in sync with the
compose file; it is the audit trail for every deviation from the defaults. See `apps/_template/app.meta.yaml`.

## Comments

A comment is earned: delete it; if nothing is lost, it stays deleted. What survives says what the
code cannot — a constraint, a library quirk, an `ADR-0002` pointer; cite an argument and the
citation is the whole comment. A module earns a header naming the risk it exists for, a util none.
Then cut the survivors again: fragments over sentences, plain words, grammar sacrificed to brevity.
