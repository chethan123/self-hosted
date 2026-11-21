# Baseline: what existed, and what we keep

As of 2026-11-21. The previous design lives on branch **`backup-2026-11-20`** (commit `dd6ec71`).
Every path cited below exists there:

```bash
git show backup-2026-11-20:apps/seafile/README.md          # read one file
git checkout backup-2026-11-20 -- apps/seafile             # bring a directory back
git ls-tree -r --name-only backup-2026-11-20               # list everything
```

**Nothing in that snapshot was ever deployed from this repo.** Every package says
`hardening_verified: false`, the backup image was never published, and restic-server never
started. That is why `main` was reset: any convention can still change for the price of an edit.

This file is the working baseline. Each item records what existed, its state, the problems a review
found, a proposed baseline, and the questions to settle. When every item has a decision, the repo
is rebuilt from it in the order of [F2](#f2-build-order). Review report (owner-only link):
<https://claude.ai/artifact/TchzcvANVb4QdKPJJNeYg5>.

---

## How to work through this

**For the owner.** Take items in board order, or pick any. Nothing is built until the baseline is
decided; then packages are rebuilt one at a time, each merged only after it runs on its VM.

**For an agent walking through it with the owner:**

1. Work on one item at a time, in board order unless the owner picks another.
2. Read the item, plus any snapshot file it cites (`git show backup-2026-11-20:<path>`). Look facts
   up in the snapshot instead of asking the owner for them.
3. Open with a summary of 3 to 5 lines: what existed, the problem, the proposed baseline.
4. Ask the item's open questions one at a time, each with your recommendation, and wait for the answer.
5. Record the outcome in the item's **Decision** line and in its row on the board (status plus a
   one-line decision). Add newly learned facts under the item. Change nothing else unless asked.
6. A decision that changes another item: note it there as a question and leave that item alone.
7. Build nothing during the walkthrough, and never write a real secret value into this file. The
   repo is public (see [R1](#r1-repository-visibility)).

Status values: `open` · `decided` · `deferred`.

## Status board

| ID | Item | Status | Decision |
|---|---|---|---|
| R1 | Repository visibility | open | |
| R2 | Layout and VM checkout model | open | |
| R3 | Validation and CI | open | |
| R4 | Documentation conventions | open | |
| R5 | Agent tooling | open | |
| P1 | VM baseline | open | |
| P2 | Edge topology: Global Caddy + Sidecar Caddy | open | |
| P3 | Global Caddy instances and routing | open | |
| P4 | TLS, certificates and headers | open | |
| P5 | Security of the LAN hop | open | |
| C1 | Package shape and per-app metadata | open | |
| C2 | Naming | open | |
| C3 | Networks and egress | open | |
| C4 | Hardening and the bring-up process | open | |
| C5 | Identity (UIDs) | open | |
| C6 | Secrets | open | |
| C7 | Data and NFS | open | |
| C8 | Images: pinning, updates, builds | open | |
| B1 | Backup model | open | |
| B2 | Backup targets | open | |
| B3 | Backup path and transport | open | |
| B4 | Backup credentials | open | |
| B5 | Database dumps | open | |
| B6 | Backup monitoring | open | |
| B7 | Where the backup services live | open | |
| B8 | Maintenance path (retention, prune, check) | open | |
| A1 | global-caddy | open | |
| A2 | backup-sidecar image | open | |
| A3 | restic-server | open | |
| A4 | portfolio | open | |
| A5 | seafile | open | |
| A6 | jellyfin | open | |
| A7 | audiobookshelf | open | |
| A8 | The package template | open | |
| F1 | Fleet inventory: what to package | open | |
| F2 | Build order | open | |

---

## R. Repository

### R1. Repository visibility

**What existed.** AGENTS.md called this a "**Private** GitHub repo", and golden rule 4 allowed
internal IPs "(private repo)". The backup image's README assumed the repo was private.

**State.** GitHub reports `chethan123/self-hosted` as **public** (checked 2026-11-21). Internal IPs,
NFS export paths, the VPN provider, every package's layout, and branch `backup-2026-11-20` are
readable by anyone. The rules kept the base domain and secrets out of committed files; this review
did not scan history for leaks.

**Proposed baseline.** Make the repo private, unless it is public on purpose. If it stays public,
treat everything committed as public: keep IPs in a gitignored inventory, not in route files.

**Open questions.**
- Is the repo meant to be public?
- If private: ghcr packages from a private repo start private, so each VM needs a pull token, or
  each package is made public by hand. Which?

**Decision.** _open_

### R2. Layout and VM checkout model

**What existed.**

```
apps/<name>/            one package per app (_template, audiobookshelf, jellyfin, portfolio, restic-server, seafile)
global-caddy/           shared reverse proxy; sites/ = one route fragment per hostname; ca/ = pinned CAs
images/backup-sidecar/  the house backup image
docs/adr/               ADR 0001-0006
docs/specs/             restic-server.md, backup-sidecar.md
AGENTS.md, CLAUDE.md -> AGENTS.md, CONTEXT.md, README.md
.agents/skills/, .claude/skills/, skills-lock.json
```

Each VM ran `git clone --filter=blob:none --sparse` then `git sparse-checkout set apps/<name>`,
seeing only its own directory. Caddy VMs checked out `global-caddy/`.

**Problems found.** With nothing shared, each package carried its own copies. `dump-loop.sh` existed
twice, every sidecar Caddyfile repeated the same header block, and the backup target list had to be
baked into an image (backup spec D2).

**Proposed baseline.**

```
apps/<name>/
  compose.yaml          the whole stack, backups included
  Caddyfile             the sidecar; imports shared/caddy/sidecar.caddy
  .env.example          every key, dummy values
  README.md             purpose, deploy steps, the reason for each exception
shared/                 checked out on every VM: git sparse-checkout set apps/<name> shared
  caddy/sidecar.caddy   headers + trusted_proxies
  dump/<engine>.sh      one short dump script per database engine
global-caddy/
images/
vm/baseline.md
scripts/check.sh
docs/adr/
```

**Open questions.**
- Add `shared/` to every VM's checkout?
- Keep ADRs in `docs/adr/`? Keep specs, or fold each into its package README once built?

**Decision.** _open_

### R3. Validation and CI

**What existed.** The gitleaks pre-commit hook (v8.24.2), which runs only where someone ran
`pre-commit install`. One workflow, `.github/workflows/backup-sidecar.yml`, built the backup image on
PRs and published it on `backup-sidecar/v*` tags. The package rules (golden rules in AGENTS.md, the
"Invariants to enforce" list in the `onboard-app` skill) were checked by reading.

**Problems found.** Nothing checked a compose file or a Caddyfile. One broken route fragment fails the
config load on every Global Caddy VM at the next reload.

**Proposed baseline.** `scripts/check.sh <package>` renders `docker compose config` and fails on:

- `ports:` on any service but the sidecar
- missing `cap_drop: [ALL]` or `no-new-privileges`; any `privileged`; a Docker socket mount
- `read_only: false`, `cap_add`, or a root user without an `x-house` reason (C1)
- an unpinned image tag without an `x-house` reason
- an NFS volume without `soft`
- a backup bind that is not `:ro`, or lacks `create_host_path: false`
- an internal network without `gateway_mode_ipv4: isolated`

CI runs it for every package, with `.env.example` copied to `.env` and dummy secrets. It also runs
`caddy adapt` on every Caddyfile (the Global Caddy one with all of `sites/`) and gitleaks.

**Open questions.**
- Which rules fail the build, and which only warn?
- Should CI also boot packages that need no NFS, device or VPN, as a smoke test?

**Decision.** _open_

### R4. Documentation conventions

**What existed.** AGENTS.md held golden rules and conventions, with a comment rule ("A comment is
earned..."). CONTEXT.md was a glossary. There were 6 ADRs, 2 specs (1,071 lines together with the
ADRs), and per package a README, an `app.meta.yaml` and heavily commented compose files.

**Problems found.** The same fact sat in 3 to 5 files. The restic-server CA setup appeared in 5
places; seafile's `read_only` exception and portfolio's Docker 28 requirement each appeared in 3.
119 of portfolio's 459 compose lines were comments.

**Proposed baseline.** Each fact is written once. Decisions go in short ADRs. A package README holds
purpose, deploy steps and exception reasons. Compose files carry no prose beyond `x-house` reasons.
A spec shrinks to its decision table once its component is built.

**Open questions.**
- Keep the CONTEXT.md glossary?
- Amend ADRs 0001-0006 in place, or start a new numbering?

**Decision.** _open_

### R5. Agent tooling

**What existed** (removed from `main` in this reset):

- **`.agents/skills/`**: 39 skills, the only copy. Codex read this directory directly; `.claude/skills/`
  held one symlink per skill for Claude Code.
- **`skills-lock.json`**: pinned 37 vendored skills from `mattpocock/skills` by path and content hash.
  22 skills set `disable-model-invocation: true` (only you could start them); 17 appeared in every
  session.
- **`/onboard-app`** (house): an interview, then a scaffold from `apps/_template/`, the route
  fragment, a hand-off to `/harden-container`, and a close-out checklist. It ended with an
  invariants list.
- **`/harden-container`** (house): direct mode (Docker local) or assisted mode (Docker on the VM;
  paste logs back). Start with every capability dropped and the root filesystem read-only, read
  `EROFS`/`EPERM`, add back one thing at a time, record it in `app.meta.yaml`.
- **AGENTS.md** with **CLAUDE.md** symlinked to it.

**Problems found.** Several vendored skills did not fit this repo (`migrate-to-shoehorn`,
`setup-ts-deep-modules`, `scaffold-exercises`, `tdd`, `teach`, `prototype`). `setup-pre-commit`
installs Husky, which conflicts with the `pre-commit` framework used here. The house skills held
their own copy of the rules.

**Proposed baseline.** Bring tooling back only after the baseline is decided:

- **AGENTS.md**: rules only, taken from the decided items here.
- **`/onboard-app`**: runs `scripts/check.sh` instead of listing rules. It reads only key names from an
  existing `.env` (`cut -d= -f1`) and looks up taken IPs and subdomains in `global-caddy/sites/`.
- **`/harden-container`**: finds needed capabilities with bcc's `capable` on the VM, adds a limits
  pass, and writes results to the compose file only.
- **Vendored skills**: about 8, or none: `grilling`, `domain-modeling`, `diagnosing-bugs`,
  `code-review`, `research`, `wizard`, `writing-for-agents`, `resolving-merge-conflicts`.

**Open questions.**
- Which skills come back, and is Codex support (`agents/openai.yaml`) still wanted?
- Is Docker going on the authoring host, so `/harden-container` can run in direct mode?

**Decision.** _open_

---

## P. Platform

### P1. VM baseline

**What existed.** Nothing in the repo; the assumptions were scattered across packages:

- Docker Engine 28+, for `gateway_mode_ipv4` (portfolio)
- Docker's default `net.ipv4.ip_unprivileged_port_start=0`, so non-root apps can bind :80
  (audiobookshelf, seafile)
- an NFS client, for NFS named volumes
- a non-root operator account whose UID owns the backups
- the sparse checkout

Most services set no log rotation, so Docker's json-file logs grew without limit.

**Proposed baseline.** `vm/baseline.md`, or a script or cloud-init, covering:

- Docker CE 28+ from Docker's apt repository
- `/etc/docker/daemon.json` with `log-opts` `max-size: 10m`, `max-file: 3`
- `nfs-common`
- the operator account and its UID
- the checkout command
- Proxmox firewall IP and MAC filters on the NIC (P5)

**Open questions.**
- A document, a script, or a Proxmox VM template?
- Which distribution? Are all VMs amd64?

**Decision.** _open_

### P2. Edge topology: Global Caddy + Sidecar Caddy

**What existed.** ADR-0001: `client --https--> Global Caddy --http--> Sidecar Caddy --> app`. The sidecar
is the per-app inbound control point (headers, auth, rate limits, path rules) and the only port the
VM exposes on the LAN. The VM boundary and Docker networks provide containment, not the sidecar.
Rejected alternative: a global proxy straight to each app.

**State.**

| Sidecar | What it does | Hardened? |
|---|---|---|
| portfolio | Google sign-in via oauth2-proxy `forward_auth`; `trusted_proxies static private_ranges` | Yes: uid 65532, :8080 inside, read-only, tmpfs `/config` `/data`, `NET_BIND_SERVICE` (the binary's file capability needs it to start), limits |
| jellyfin | Routes 4 hostnames by `Host` (needs `BASE_DOMAIN`) | No: root, writable, no limits |
| restic-server | TLS on :443 (`tls internal`), routes 3 paths | No (limits set) |
| seafile | Pass-through; hardcodes `X-Forwarded-Proto https` | No (limits set) |
| audiobookshelf | Pass-through | No |

**Problems found.** Without `trusted_proxies`, every app except portfolio sees each client as the
Global Caddy's IP, over HTTP. Rate limiting by client IP at the sidecar, one of ADR-0001's stated
reasons, cannot work. Plain-HTTP sidecars also bound `./volumes/caddy`, which held nothing.

**Proposed baseline.** Keep the sidecar: an internal network cannot publish a port, so the sidecar is
what lets an app have no internet access. Use one standard block everywhere: portfolio's shape, plus
`trusted_proxies static <Global Caddy IPs>`, plus the shared header snippet, with no volume.

**Open questions.**
- What are the Global Caddy IPs, for `trusted_proxies`?
- Should more apps get a sign-in gate like portfolio's, as a shared pattern?

**Decision.** _open_

### P3. Global Caddy instances and routing

**What existed.** ADR-0002: several Global Caddy instances behind round-robin DNS A records, routing
to `VM-IP:port`. Routes are hand-maintained: one `global-caddy/sites/<hostname>.caddy` fragment per
hostname, imported inside the `*.{$BASE_DOMAIN}` block. Each node sparse-checks-out `global-caddy/`,
builds its own image (`build: .`, tag `caddy-cloudflare:2.10`) and runs
`docker exec caddy caddy reload --config /etc/caddy/Caddyfile` after a pull. Rejected alternatives:
caddy-docker-proxy and Docker labels (they cannot see other VMs' daemons), and Swarm.

**State.** The number of instances and their IPs are not recorded in the repo.

**Problems found.**
- Round-robin DNS has no health check, so clients keep reaching a dead instance.
- Each node builds with an unpinned DNS module (`xcaddy build --with github.com/caddy-dns/cloudflare`),
  so the "identical" nodes differ.
- ADR-0005 deferred a versioned image "until a local registry exists"; ghcr now fills that role.

**Proposed baseline.** Two instances on a keepalived floating IP (or one, if failover was never
needed). The image is built in CI and pushed to ghcr with a pinned module. CI runs `caddy adapt`
before any route merges.

**Open questions.**
- How many instances run today, on which IPs?
- Is outside access through port forwarding, Tailscale, or LAN only?
- Was failover ever needed?

**Decision.** _open_

### P4. TLS, certificates and headers

**What existed.** ADR-0005: one wildcard certificate per zone via DNS-01 (Cloudflare; the token is a
file-secret, `secrets/dns_token.txt`), because per-host certificates on several instances would hit
Let's Encrypt limits. Three wildcard blocks:

- `*.{$BASE_DOMAIN}`: imports `sites/*.caddy`
- `*.blr.{$BASE_DOMAIN}`: `qbit.blr` and `tv.blr` go to Tailscale peer `100.87.160.34`, with a Host
  header override
- `*.drive.{$BASE_DOMAIN}`: goes to `10.1.1.5:80`

The shared `security_headers` set X-Frame-Options SAMEORIGIN, nosniff, X-XSS-Protection,
HSTS with `includeSubDomains; preload`, Referrer-Policy, Permissions-Policy, and removed `Server`.
An explicit `http://` block redirected to HTTPS. The ACME email came from `.env`.

**Problems found.**
- `X-XSS-Protection` is deprecated.
- `preload` matters only if the domain is submitted to the preload list.
- The explicit redirect block repeats Caddy's automatic HTTPS redirects.
- Sidecars repeated HSTS, which browsers ignore over plain HTTP.

**Proposed baseline.** Keep the wildcard design. Drop `X-XSS-Protection` and sidecar HSTS, and drop
the redirect block after checking that Caddy's automatic redirect covers the same hosts.

**Open questions.**
- Are `*.blr` and `*.drive` still in use?
- Keep `preload`?

**Decision.** _open_

### P5. Security of the LAN hop

**What existed.** The Global Caddy to sidecar hop is plain HTTP for every app (ADR-0001). restic-server
alone terminated TLS with a pinned internal CA (restic-server spec D10). Its argument: the hop
carries every app's backup credential, and a compromised app VM shares `10.1.1.0/24` and could
ARP-spoof it.

**Problems found.** The same segment carries Seafile logins, portfolio session cookies and Jellyfin
credentials in plain HTTP. The threat applies to every hop, not only backups.

**Proposed baseline.** Turn on the Proxmox firewall with IP and MAC filtering on every VM's NIC, which
blocks spoofing for all hops at once. Backups use direct TLS (B3).

**Open questions.**
- Are all app VMs on one bridge or VLAN?
- Is the Proxmox firewall on today?

**Decision.** _open_

---

## C. Package conventions

### C1. Package shape and per-app metadata

**What existed.** A package held:

- `docker-compose.yml`
- `docker-compose.backup.yml`, merged by `COMPOSE_FILE` in `.env`
- `Caddyfile`
- `.env.example`
- `app.meta.yaml`
- `README.md`
- `secrets/.gitkeep`
- sometimes `scripts/`

`app.meta.yaml` was the "contract and deviation audit trail". Its base fields were `name`,
`hostname`, `vm_ip`, `sidecar_port`, `needs_egress`, `secrets_mode`, `hardening_verified`,
`services.<svc>.{image_type, read_only, caps_added, tmpfs_paths}`, `backup`, `nfs_volumes` and
`owner`. Packages extended it differently: `routes`, `deviations`, `upstream_edits`, `networks`,
`cpus_unset`, `runs_as_root`, `unprivileged_port_bind`, `devices`, `network_mode`,
`non_root_mode`, `components_disabled`, `min_docker_engine`, `limits_verified` and `caddy_pin`.
Nothing parsed it.

**Problems found.** It repeated the compose file (capabilities, tmpfs, images, backup sources) and the
route fragments (hostname, IP, port). With no parser, it could only drift.

**Proposed baseline.** Four files: `compose.yaml`, `Caddyfile`, `.env.example`, `README.md`, plus
`secrets/.gitkeep`. An exception sits beside the setting it loosens, as a Compose extension field
that the check script reads:

```yaml
services:
  seafile:
    read_only: false
    x-house:
      read_only: "phusion runit creates supervise/ dirs under /etc/service at runtime"
```

The README header carries the VM IP and hostnames.

**Open questions.**
- Is any machine-readable per-app file still wanted, for example to generate restic-server's
  password file later?
- `compose.yaml` or `docker-compose.yml`?

**Decision.** _open_

### C2. Naming

**What existed.** The app service is named after the app slug, never `app`, because Compose registers
the service name as the DNS name the sidecar proxies to. Every service set `container_name:`:
`caddy-<app>` for the sidecar and the service name otherwise. Plain `caddy` was reserved for the
Global Caddy. Recorded exceptions:

- jellyfin: Jellyfin runs in gluetun's namespace and is reached as `gluetun:8096`
- restic-server: three upstreams
- portfolio: keeps upstream's `app`

**Problems found.** A fixed `container_name` forces `--name` on every `docker compose run`, such as
`backup run` or `dump verify`. Without it, the one-off container collides with the running one.
Several READMEs carried that warning.

**Proposed baseline.** Keep the slug rule. Drop `container_name` and set `name: <slug>` at the top of
the compose file instead. Containers then read `seafile-db-1` on every VM, and `compose run` needs
no `--name`.

**Open questions.**
- Drop `container_name`?

**Decision.** _open_

### C3. Networks and egress

**What existed.**

| Network | Type | Members | Purpose |
|---|---|---|---|
| `edge` | bridge | sidecar, plus the app iff `needs_egress` | the published port; egress |
| `frontend` | `internal: true` | sidecar, app | sidecar ⇄ app |
| `backend` | `internal: true` | app, db | app ⇄ db; the sidecar cannot reach the db |

Portfolio ran 8 networks instead: `ingress`, `caddy-app`, `backend`, `caddy-gate`, `worker-proxy`,
`egress-proxy`, `egress-gate` and `backup-egress` (A4). Its internal networks set
`com.docker.network.bridge.gateway_mode_ipv4: isolated` and `enable_ipv6: false`.

**Problems found.**
- Portfolio found that without `gateway_mode_ipv4: isolated` (Docker 28+; ignored on 26, refused on
  27), containers on an "internal" network still have a route to the host, and so to its published
  ports. That applies to every package, not just portfolio.
- `needs_egress` stopped meaning anything. Every backup sidecar needs egress, portfolio redefined
  the flag, and jellyfin and restic-server have egress on only some services.

**Proposed baseline.** Keep the three networks. Set `gateway_mode_ipv4: isolated` on every internal
network. Drop the flag: egress is membership of `edge`, and the check script lists which services
have it.

**Open questions.**
- Does the backup sidecar join `edge`, or get its own egress network as in portfolio?

**Decision.** _open_

### C4. Hardening and the bring-up process

**What existed.** ADR-0003 set the defaults:

- `cap_drop: [ALL]`, adding back only proven needs
- `no-new-privileges:true`
- non-root
- `read_only: true` with sized tmpfs
- `pids_limit`, `mem_limit` and `cpus`
- pinned tags
- never `privileged`, never the Docker socket, default seccomp

ADR-0004: the authoring host has no Docker, so the bring-up loop runs on the VM. Two exceptions
applied house-wide:

- **Sidecar Caddy:** `read_only: false`, no limits.
- **Database engines:** start as root with `CHOWN SETUID SETGID DAC_OVERRIDE FOWNER`.

**Recorded exceptions, all unverified:**

| Package | Service | Exception | Reason given |
|---|---|---|---|
| seafile | seafile | writable root; 7 caps (`CHOWN DAC_OVERRIDE FOWNER SETUID SETGID KILL AUDIT_WRITE`) | phusion runit writes `/etc/service/*/supervise`; `enterpoint.sh` edits `/etc/passwd`, cron, scripts |
| jellyfin | gluetun | `NET_ADMIN`, `/dev/net/tun`, writable root | creates the WireGuard tunnel, rewrites iptables |
| jellyfin | jellyfin | writable root; 5 caps; `/dev/dri`; no `cpus` | s6-overlay init chowns `/config`; VAAPI; transcoding uses every core |
| jellyfin | rclone-webdav | root, writable root | `apk add rclone` at each start |
| portfolio | gate | root + `DAC_READ_SEARCH` | image sets no USER; must read the allowlist file |
| portfolio | caddy | `NET_BIND_SERVICE` | the binary's file capability needs it to start |
| portfolio | worker, egress-proxy | no `cpus` | upstream's limits |

**State.** `hardening_verified: false` on every package. Each capability list is a starting guess.

**Proposed baseline.** Keep the posture. Promote portfolio's two measured shapes to the template: the
sidecar block (P2) and Postgres as `user: 70:70` with zero capabilities. That removes both house-wide
exceptions. At first bring-up, record only measured results, in the compose file.

**Open questions.**
- Accept a writable root for seafile and jellyfin, or retry with tmpfs mounts at bring-up?
- Install Docker on the authoring host to run the loop locally for services that need no NFS, device
  or VPN? The host is arm64; check that images exist for it.

**Decision.** _open_

### C5. Identity (UIDs)

**What existed.** Vanilla and self-built images use `user: UID:GID`. linuxserver.io images use
`PUID`/`PGID`, because their init needs root to fix ownership. UIDs in use:

| Package | Service | UID:GID |
|---|---|---|
| audiobookshelf | audiobookshelf | 975:975 |
| jellyfin | jellyfin (PUID/PGID), metube | 975:975 |
| jellyfin | rclone-webdav | root (meant to serve as 975; see A6) |
| restic-server | rest-server, both rclone | 1000:1000; the NFS export is owned 1000:1000 |
| seafile | seafile | starts root, servers run as 8000 (`NON_ROOT=true`) |
| seafile | redis | 999:1000 |
| portfolio | db / caddy / app, worker | 70:70 / 65532:65532 / image `USER node` (1000) |
| any | backup sidecar, dump | the operator's UID (`BACKUP_UID`, `DUMP_UID` in portfolio) |

**Proposed baseline.** Keep the rules, and list each package's UIDs in its README.

**Open questions.**
- Use one fleet UID (975?) for every service that writes NFS exports?
- Use one operator UID across all VMs?

**Decision.** _open_

### C6. Secrets

**What existed.** A "hybrid" model: `env_file: .env` for config and for images that read only
environment variables, and Docker file-secrets (`*_FILE`, `/run/secrets/`) for high-value secrets
where the image supports them. In practice:

| Package | Mode | Why |
|---|---|---|
| seafile | env | reads every credential via `os.getenv` |
| portfolio | env | the Postgres password has 3 consumers; oauth2-proxy does not trim a `*_FILE` newline |
| audiobookshelf | env | no secrets |
| jellyfin | hybrid | WireGuard key as a file; jellystat has no `*_FILE` |
| restic-server | file-secrets | htpasswd, rclone configs, SSH key |

The template's app service had `env_file: .env`, handing it every key, including the backup push
token.

**Proposed baseline.** Secrets default to `.env`, mode 0600, passed to each service by name through
`environment:`. Use a file-secret only where the image reads `*_FILE` and is the value's only
consumer. Required keys use `${VAR:?message}`.

**Open questions.** None beyond agreement.

**Decision.** _open_

### C7. Data and NFS

**What existed.** State lives in gitignored `volumes/<service>/` binds. NFS exports are named volumes
with the `local` driver and the options `addr=<ip>,rw,soft,timeo=30,retrans=3,intr`. They are always
`soft`, because `hard` caused hangs. Read-only is enforced at the container mount (`:ro` by default).
Databases (SQLite, MariaDB, Postgres) never live on NFS. NFS server `192.168.86.250` exports:

| Export | Used by |
|---|---|
| `/export/audiobooks`, `/export/podcasts` | audiobookshelf (both rw) |
| `/export/jellyfin` | jellyfin `/media` (rw) |
| `/export/youtube` | metube (rw), jellyfin (ro) |
| `/export/jellyfin-share` | rclone-webdav (rw), jellyfin (ro) |
| `/export/restic` | restic-server's `nfs` target (rw, owned 1000:1000, no root squash of that UID) |

**Problems found.** `intr` has been ignored by the Linux NFS client since kernel 2.6.25.

**Proposed baseline.** Keep the model, and drop `intr`.

**Open questions.** None beyond agreement.

**Decision.** _open_

### C8. Images: pinning, updates, builds

**What existed.**
- **Pinning.** Every tag was pinned, except portfolio's app image, which floats its major
  (`portfolio-app:${APP_VERSION:-2}` with `pull_policy: always`), and `postgres:17-alpine`, which
  floats its minor through one anchor.
- **Caddy versions.** Sidecars use `caddy:2.8-alpine`. Portfolio holds 2.8 on purpose:
  GHSA-6365-7ppr-5r92 affects its `forward_auth` shape from 2.11.0; revisit when 2.11.5-alpine
  ships.
- **Builds.** The Global Caddy image is built on each node; the backup image is built in CI.
- **Updates.** No update mechanism.

**Problems found.** Pinned tags with no updater fall months behind security fixes.

**Proposed baseline.** Renovate opens a pull request per image bump. Build every house image (Global
Caddy, backup) in CI, push it to ghcr, and pin it by version.

**Open questions.**
- Should Renovate auto-merge patch releases?
- Pin by digest as well as tag?

**Decision.** _open_

---

## B. Backups

### B1. Backup model

**What existed.** ADR-0006, `docs/specs/backup-sidecar.md` and `docs/specs/restic-server.md`.

- **Server side.** restic-server, one VM, speaks restic's REST protocol to clients, writes to 3
  targets, and runs **append-only** with **private repositories**. A compromised app VM can add
  snapshots to its own repositories, cannot delete, and cannot touch another app's.
- **Server-side rejections.** Apps writing to cloud storage directly (each VM would hold
  delete-capable keys), one replicated repository (it copies corruption), and the rclone volume
  plugin (`CAP_SYS_ADMIN`, FUSE, write-back cache).
- **Client side.** A sidecar per app, not a central puller, which would hold read access to every
  VM. It runs non-root, as the account that owns the backup set. The backup set is exactly the `:ro`
  binds under `/backup/<name>`.
- **Rules.** Databases are dumped, never copied live. An unreadable file fails the run (restic exit
  3). One repository password per app, escrowed out of band.

**State.** Only portfolio had a backup file. The image was never released, restic-server never
started, and the maintenance VM was never built.

**Proposed baseline.** Keep the model; B2 to B7 simplify its parts.

**Open questions.** None beyond agreement.

**Decision.** _open_

### B2. Backup targets

**What existed.**

| Target | Server | Store |
|---|---|---|
| `nfs` | `restic/rest-server:0.14.0` | NFS `/export/restic` |
| `rsync-net` | `rclone serve restic` (1.75.1, never below 1.75.0) | rsync.net over SFTP; host key pinned in `known_hosts`, verified out of band |
| `pcloud` | `rclone serve restic` | pcloud (US region); OAuth token has a zero expiry, so its config is read-only |

Each app got three independent repositories (no replication), at 3× upload and storage.

**State.** rsync.net values were placeholders until a real account exists. Whether rsync.net's ZFS
snapshots are immutable was never verified; they are the only copy that survives a compromise of
restic-server itself.

**Proposed baseline.** NFS plus rsync.net, once its snapshots are confirmed. Drop pcloud: it adds a
service, a login per app and a nightly upload, without that protection.

**Open questions.**
- Keep pcloud for provider diversity?
- Does the rsync.net account exist, and are its snapshots confirmed?

**Decision.** _open_

### B3. Backup path and transport

**What existed.** Clients used `rest:https://backup.{$BASE_DOMAIN}/<target>/<slug>/`, which went
through the Global Caddy to restic-server's sidecar on :443 (`tls internal`). The Global Caddy
pinned that CA:

1. Bring up restic-server's Caddy.
2. Copy `volumes/caddy/pki/authorities/local/root.crt` to `global-caddy/ca/backup-ca.crt` and commit it.
3. Uncomment `sites/backup.caddy` and reload every Caddy node.

The route shipped commented out, because a missing CA file fails the whole config load. Losing
restic-server's `volumes/caddy` regenerated the CA and broke the route until steps 2 and 3 were
repeated.

**Proposed baseline.** Clients connect straight to restic-server at `https://10.1.1.100/<target>/<slug>/`,
with no Global Caddy route. Generate the CA offline once: the key becomes a restic-server
file-secret, and the certificate is baked into the backup image (or kept in `shared/`). The Global
Caddy then leaves the credential path, and backups keep working when it is down.

**Open questions.**
- Bypass the Global Caddy for backups?
- Use the IP in URLs, or a LAN DNS name?

**Decision.** _open_

### B4. Backup credentials

**What existed.** Each app held 4 file-secrets: `restic-password` (one per app, escrowed out of band)
and `backup-{nfs,rsync-net,pcloud}.env` (`RESTIC_REST_USERNAME=<slug>`, plus a password). restic has
no `RESTIC_REST_PASSWORD_FILE`, so the login came from a dotenv file through resticprofile's
`env-file`. restic-server held `htpasswd-{nfs,rsync-net,pcloud}`, one bcrypt line per app per file.
After an edit, the backends had to restart (single-file bind mounts).

**Proposed baseline.** One REST login per app, so 2 secrets per app. One htpasswd file on restic-server,
mounted into each backend. The three logins all leak together from the app VM anyway. Splitting
them only contains a compromised rclone backend, and a stolen login there can only add snapshots
or read ciphertext.

**Open questions.**
- One login per app?

**Decision.** _open_

### B5. Database dumps

**What existed.** Every database gets a dump service in its engine's image, at the same tag as the
server (`pg_dump` refuses a newer server), running as the backup set's owner on `backend`.
`dump-loop.sh` (Postgres, about 330 lines of POSIX sh):

- dumps daily at `DUMP_AT` (UTC hour) and prunes after `DUMP_KEEP_DAYS`
- refuses unless free space ≥ 2 × database size + 1 GiB
- writes `pg_dump -Fc` to a `.part` file, decodes the whole archive to verify it, refuses a dump
  under half the previous size, then renames it into place (mode 0640)
- writes JSON markers and retries at +15, +30 and +60 minutes
- has a healthcheck on the newest dump's age (30 h)

Only the Postgres version existed; MariaDB (seafile) and SQLite (audiobookshelf, jellyfin) were
deferred.

**Proposed baseline.** One short script per engine in `shared/dump/`. The backup sidecar refuses to
report "up" when the newest dump is older than 26 h, which replaces the markers, healthcheck and
shrink check. Audiobookshelf's own scheduled backups (`/metadata/backups`) serve as its dump.
Seafile: `mariadb-dump` first, then the block store (Seafile's documented order).

**Open questions.**
- Can Jellyfin 10.11's built-in backup be scheduled, or does it need a SQLite `.backup` dump?
- Keep the free-space check?

**Decision.** _open_

### B6. Backup monitoring

**What existed.** One Uptime Kuma push per run: `status=up` with the elapsed time, or `status=down`
naming the failed targets. A missed heartbeat is the alert. Kuma is at `status.{$BASE_DOMAIN}`
(`192.168.86.250:8080`). Nothing monitored restic-server itself.

**Proposed baseline.** Keep it, and add the dump freshness check (B5). Optionally add Kuma HTTP checks
per hostname and one for restic-server.

**Open questions.**
- Monitor every hostname too?

**Decision.** _open_

### B7. Where the backup services live

**What existed.** A second file, `docker-compose.backup.yml`, merged through
`COMPOSE_FILE=docker-compose.yml:docker-compose.backup.yml` in `.env`. It existed so that vendored
upstream compose files never needed editing. `include:` was rejected, because included files
cannot name the parent's networks.

**Proposed baseline.** Put backup services in the main compose file. Keep an override only for a
compose file vendored from upstream, which today means portfolio.

**Open questions.** None beyond agreement.

**Decision.** _open_

### B8. Maintenance path (retention, prune, check)

**What existed (designed, never built).** A separate VM, normally powered off, holds every repository
password and full storage credentials.

- **Commands.** `forget --keep-within <policy>`, then `prune`, then `check` with
  `--read-data-subset` on a rotation.
- **Retention.** Never `--keep-daily/weekly/monthly`: an attacker can inject newer-dated snapshots
  that push the real ones out.
- **Routes.** NFS through restic's local backend as UID 1000; rsync.net through `sftp:`; pcloud
  through `rclone:`. Restart the rclone servers afterwards, because of stale caches.
- **pcloud.** `rclone cleanup` needs the full account password.

**Open questions.**
- What retention policy?
- When to build it: before or after the first app backups?

**Decision.** _open_

---

## A. Components (what each package held)

### A1. global-caddy

**What existed.** These files, with deploy steps in its README:

- `Caddyfile`: global email, the `tls_wildcard` and `security_headers` snippets, 3 wildcard blocks,
  the HTTP redirect
- `Dockerfile`: `caddy:2.10-builder` + `xcaddy --with github.com/caddy-dns/cloudflare`, then
  `caddy:2.10`
- `docker-compose.yml`: ports 80, 443 and 443/udp; read-only; `NET_BIND_SERVICE`; 2 GB memory;
  256 PIDs; tmpfs `/tmp`; mounts `Caddyfile`, `sites/`, `ca/` (a directory, so a missing file
  cannot become a directory), `volumes/data`, `volumes/config`
- `.env.example`: `BASE_DOMAIN`, `ACME_EMAIL`
- `secrets/dns_token.txt`: the Cloudflare token, scoped to Zone:DNS:Edit
- `sites/`: 35 fragments (F1)
- `ca/`: empty

**State.** It presumably runs today in some form; the repo does not record the nodes. A node that
checks out `global-caddy/` from `main` must be pinned to `backup-2026-11-20` before any `git pull`.
On `main` the directory is gone, and a reload after the pull would fail.

**Proposed baseline.** P3 and P4. Back up `volumes/data`, or accept re-issuing certificates.

**Decision.** _open_

### A2. backup-sidecar image

**What existed.**

- **Base.** `FROM ghcr.io/creativeprojects/resticprofile:0.33.1` (restic 0.19.1, rclone,
  resticprofile) plus `apk add supercronic`, because upstream schedules with busybox `crond`, which
  needs root.
- **`profiles.yaml`.** A `base` profile (password file, cache `/cache`, `initialize: true`, source
  `/backup`, host and tag = slug, exclude `*.part`, `exclude-caches`) and one profile per target.
  Global lock retry 1 m, stale lock after 2 h.
- **Entrypoint `backup`.** `schedule` writes one crontab line and execs supercronic; `run` backs up
  each target in turn, then sends one Kuma push; anything else passes through to resticprofile.
  It refuses: uid 0, missing variables or secrets, an empty `/backup`, an empty source, an
  unwritable cache.
- **Inputs.** `BACKUP_SLUG`, `BASE_DOMAIN`, `BACKUP_SCHEDULE`, `BACKUP_PING_URL` (or `none`), the 4
  secrets, the `/backup/*` binds, `/cache`, and a tmpfs on `/resticprofile`.
- **Release.** `.github/workflows/backup-sidecar.yml` builds linux/amd64, smoke-tests as a non-root
  user, and pushes on tag `backup-sidecar/v1.0.0`. After the first push, the package must be made
  public by hand.

**State.** The tag was never pushed, so the image does not exist.

**Open questions.**
- Keep the house image, or use the official `restic/restic` image with a script from `shared/`?
- With B2 to B4 decided, the image changes: 2 targets, 1 login, a baked CA, direct URL.

**Decision.** _open_

### A3. restic-server

**What existed.** VM `10.1.1.100`, `backup.{$BASE_DOMAIN}`, sidecar port 443. It replaces the old
`restic.{$BASE_DOMAIN}` at `10.1.1.200`.

| Service | Image | Runs as | Networks | Notes |
|---|---|---|---|---|
| caddy | caddy:2.8-alpine | root | edge, frontend | `tls internal`; `handle_path /nfs/*`, `/rsync-net/*`, `/pcloud/*` |
| rest-server | restic/rest-server:0.14.0 | 1000:1000 | frontend | `PASSWORD_FILE=/run/secrets/htpasswd-nfs`; otherwise it creates an empty `.htpasswd` on NFS and returns 401 to everyone |
| rclone-rsync-net | rclone/rclone:1.75.1 | 1000:1000 | edge, frontend | `serve restic --addr :8080`; the image entrypoint is already `rclone`; tmpfs `/tmp` 256 MB |
| rclone-pcloud | rclone/rclone:1.75.1 | 1000:1000 | edge, frontend | as above, remote `pcloud:restic` |

Secrets: `htpasswd-{nfs,rsync-net,pcloud}`, `rclone-{rsync-net,pcloud}.conf`, `rsync-net.key`,
`rsync-net.known_hosts`. Environment: `SIDECAR_PORT=443`, `BASE_DOMAIN`, `NFS_SERVER`,
`RSYNC_NET_REMOTE_PATH`.

**Known open items.**
- rclone checks a bcrypt password on every request, unmeasured (rest-server caches for 60 s).
- One app can fill a target and stop everyone's backups.
- Nothing monitors the server.
- `handle_path`'s trailing-slash behaviour was never checked.
- Backrest (`10.1.1.250`) may still point at `10.1.1.200`.

**Open questions.**
- Decided mostly by B2 to B4. Does Backrest stay?

**Decision.** _open_

### A4. portfolio

**What existed.** Migrated from `github.com/chethan123/portfolio` (`compose.yaml` at v2.0.3). VM
`10.1.1.10` (not yet created). Requires Docker 28+.

| Service | Image | Runs as | Networks | Notes |
|---|---|---|---|---|
| db | postgres:17-alpine | 70:70 | backend | zero capabilities; tmpfs `/var/run/postgresql`; data dir `./volumes/db/data`, a bind-backed named volume, pre-created |
| dump | postgres:17-alpine | `DUMP_UID` | backend | `scripts/dump-loop.sh`, vendored byte-identical from upstream |
| app | portfolio-app:${APP_VERSION:-2} | image `node` | backend, caddy-app | `AUTH_GATE=external`; `PUBLIC_ORIGIN=https://portfolio.${BASE_DOMAIN}`; no egress |
| worker | same image, `server/price-worker.ts` | image `node` | worker-proxy | unix socket on a 1 MB tmpfs volume (uid 1000, 0770); egress only through the proxy |
| egress-proxy | same image, `server/egress-proxy.ts` | image `node` | worker-proxy, egress-proxy | CONNECT only, to five Yahoo hosts, ClientHello pinned |
| gate | oauth2-proxy:v7.15.4-alpine | root + `DAC_READ_SEARCH` | caddy-gate, egress-gate | Google; allowlist `secrets/allowed-emails.txt`; cookie SameSite lax |
| caddy | caddy:2.8-alpine | 65532:65532 | ingress, caddy-app, caddy-gate | `forward_auth` to gate; :8080 inside |
| backup | backup-sidecar:1.0.0 | `DUMP_UID` | backup-egress | set: `volumes/dumps`, `secrets/`, `.env`; 03:00 UTC |

Setup needs a Google OAuth client with the exact redirect URI
`https://portfolio.<domain>/oauth2/callback`; changing the subdomain means re-enrolling passkeys. The
`upstream_edits` list in `app.meta.yaml` recorded every change to replay when re-vendoring.

**Open questions.**
- Keep upstream's names (`app`, seven networks) for easy diffs, or rename to house names?
- Keep both floating tags?

**Decision.** _open_

### A5. seafile

**What existed.** Seafile CE 13.0.25, core only (SeaDoc, notification server, AI, face recognition,
OnlyOffice and Collabora off). VM `10.1.1.8`, `files.{$BASE_DOMAIN}`. A route exists; whether an
instance runs there today is not recorded.

| Service | Image | Runs as | Networks | Notes |
|---|---|---|---|---|
| caddy | caddy:2.8-alpine | root | edge, frontend | sets `X-Forwarded-Proto https` (Seafile derives its scheme from it) |
| seafile | seafileltd/seafile-mc:13.0.25 | root, then `su seafile` (8000) | frontend, backend | writable root, 7 caps; no egress, so no email |
| db | mariadb:10.11.18 | entrypoint root, then mysql | backend | 5 caps; tmpfs `/tmp`, `/run/mysqld` |
| redis | redis:7.4.9-alpine | 999:1000 | backend | zero caps; `--save "" --appendonly no` (cache only) |

**Facts.**
- **Two-phase first boot.** Start with `NON_ROOT=false`, then `chown -R 8000:8000 volumes/seafile`
  and set `NON_ROOT=true`. Going straight to `true` runs `chmod -R a+rwx /shared/`.
- **Post-install.** Write `SERVICE_URL`, `FILE_SERVER_ROOT`, `CSRF_TRUSTED_ORIGINS` and
  `SECURE_PROXY_SSL_HEADER` into `seahub_settings.py`; otherwise login returns 403.
- **Proxy.** Upstream's caddy-docker-proxy was dropped, because it needs the Docker socket.
- **Storage.** All local: the block store does not tolerate `soft` NFS.

**Open questions.**
- Does a Seafile instance with data run today?
- Is email (egress) wanted?

**Decision.** _open_

### A6. jellyfin

**What existed.** VM `10.1.1.2`. Four hostnames (`tv`, `metube`, `jellyshare`, `jellystats`) share one
sidecar port, routed by `Host`. Migrated from a running stack with existing data.

| Service | Image | Runs as | Networks | Notes |
|---|---|---|---|---|
| caddy | caddy:2.8-alpine | root | edge, frontend | needs `BASE_DOMAIN` for its host matchers |
| gluetun | qmcgaw/gluetun:v3.41.1 | root, `NET_ADMIN` | edge, frontend | ProtonVPN WireGuard; key at `secrets/wireguard_private_key` (root:root 0600) |
| jellyfin | linuxserver/jellyfin:10.11.11 | PUID/PGID 975 | gluetun's namespace | reached as `gluetun:8096`; `/dev/dri`; 4 GB memory |
| metube | alexta69/metube:2026.07.21 | 975:975 | edge, frontend | direct egress, not through the VPN |
| rclone-webdav | alpine:3.24.1 + `apk add rclone` | root | edge, frontend | WebDAV for `jellyshare`; `RCLONE_USER`/`RCLONE_PASS` |
| jellystat | cyfershepard/jellystat:1.1.11 | image default | frontend, backend | reaches Jellyfin at `http://gluetun:8096` |
| jellystat-db | postgres:18.4-alpine | entrypoint root | backend | mount `/var/lib/postgresql`, not `/data` (Postgres 18 layout; the wrong path starts an empty cluster) |

**Likely bug.** rclone's `--uid 975 --gid 975` only change the owner it *reports*. The process runs as
root, so WebDAV uploads are probably owned by root, or by nobody under root squash. Fix: use the
`rclone/rclone:1.75.1` image with `user: "975:975"`, read-only, off `edge`. rclone reads
`RCLONE_USER` and `RCLONE_PASS` itself.

**Open questions.**
- Still want all 7 services on one VM? They share NFS exports, the reason they were grouped.
- How will the existing data cut over (config, the jellystat cluster)?

**Decision.** _open_

### A7. audiobookshelf

**What existed.** VM `10.1.1.3`, `audiobooks.{$BASE_DOMAIN}`. Migrated from a running stack whose
`init.sh`, `start.sh`, `stop.sh` and `session.sh` were dropped.

| Service | Image | Runs as | Networks | Notes |
|---|---|---|---|---|
| caddy | caddy:2.8-alpine | root | edge, frontend | pass-through |
| audiobookshelf | advplyr/audiobookshelf:2.35.1 | 975:975 | edge, frontend | listens on :80 as non-root (Docker's port sysctl); read-only; tmpfs `/tmp` 1 GB; healthcheck lists `/audiobooks` |

`/config` (SQLite: library, users, progress) must stay local. `/metadata` is regenerable cache, and
also holds Audiobookshelf's own scheduled backups. Both NFS libraries are rw, for metadata
embedding, the m4b merge tool, uploads and renames. Egress is needed for metadata lookups and
podcast downloads.

**Open questions.**
- Tighten `/audiobooks` to read-only if the write-back features go unused?
- Use its built-in backups as the backup set (B5)?

**Decision.** _open_

### A8. The package template

**What existed.** `apps/_template/`: 7 files, 691 lines.

- **Compose file.** Sidecar (root, writable, no limits), `example-app` (`user: 1000:1000`,
  read-only, `env_file: .env`) and `db` (`postgres:16.4`, 5 caps).
- **Backup file.** `backup` plus `dump` (`postgres:16.4`).
- **Other files.** `app.meta.yaml`, the Caddyfile, `.env.example`, a README with deploy and restore
  steps, and `scripts/dump-loop.sh`.

**Proposed baseline.** Rebuild it from the decided items: portfolio's sidecar and Postgres shapes,
one compose file, `x-house` exceptions, `shared/` snippets and the check script. It is the last
thing written before the first package (F2).

**Decision.** _open_

---

## F. Fleet

### F1. Fleet inventory: what to package

All 35 Global Caddy routes on the snapshot (`global-caddy/sites/`). "Package" means an `apps/` package
existed.

| Hostname | Upstream | Package | Notes |
|---|---|---|---|
| tv, metube, jellyshare, jellystats | 10.1.1.2:80 | jellyfin | |
| audiobooks | 10.1.1.3:80 | audiobookshelf | |
| photos | 10.1.1.4:80 | — | |
| drive | 10.1.1.5:80 | — | `*.drive` also goes here |
| paper | 10.1.1.6:80 | — | |
| books | 10.1.1.7:80 | — | |
| files | 10.1.1.8:80 | seafile | |
| portfolio | 10.1.1.10:80 | portfolio | |
| getbooks, getindex, getmovies, getmusic, getshows, getsubtitles | 10.1.1.99 (8787, 9696, 7878, 8686, 8989, 6767) | — | *arr stack, no sidecar |
| libre | 10.1.1.99:3000 | — | |
| backup | https://10.1.1.100 | restic-server | commented out until the CA existed |
| restic | 10.1.1.200:80 | — | old restic; retire at cutover |
| backrest | 10.1.1.250:9898 | — | Backrest UI |
| syncthing-1 | 10.1.1.254:8384 | — | |
| router | 10.1.1.1:80 | — | infrastructure |
| prox1 | https://192.168.86.201:8006 | — | Proxmox |
| prox2 | 192.168.86.22:8006 | — | **plain HTTP to an HTTPS-only port; probably broken** |
| dns, dns2, dns3 | 192.168.86.31, .32, .33 :8080 | — | infrastructure |
| dns-sync | 192.168.86.106:8080 | — | |
| speed | 192.168.86.31:8888 | — | |
| ha | 192.168.86.34:8123 | — | Home Assistant; `flush_interval -1` |
| nfs | 192.168.86.250:80 | — | the NAS |
| status | 192.168.86.250:8080 | — | Uptime Kuma |
| syncthing-ext | 192.168.86.50:8384 | — | |
| photoz | 100.94.153.17 | — | Tailscale peer |
| qbit.blr, tv.blr | 100.87.160.34 | — | Tailscale peer, in the `*.blr` block |

**Open questions.**
- Which unpackaged app VMs hold data worth packaging (backups, hardening)? Candidates: photos
  (`.4`), drive (`.5`), paper (`.6`), books (`.7`), the *arr stack and libre (`.99`), backrest
  (`.250`), syncthing (`.254`).
- Which routes are dead and can go?

**Decision.** _open_

### F2. Build order

Proposed: each phase closes with a gate, and a package merges to `main` only after its gate passes on
its VM.

1. **Foundation.** Decided baseline; lean template; `shared/`; `scripts/check.sh`; CI (compose,
   Caddyfiles, gitleaks); VM baseline; Global Caddy image in CI.
   *Gate: CI passes on the template.*
2. **Backup path.** Release the backup image with restic-server's CA; bring up restic-server on NFS
   and rsync.net.
   *Gate: a test client backs up to, and restores from, both targets.*
3. **Pilot: audiobookshelf.** Closest to the template; hardening loop on its VM; backups from its
   built-in backup files.
   *Gate: runs read-only with measured capabilities; old stack retired.*
4. **Portfolio.** New VM, no existing data; proves the Postgres shape and the dump script.
   *Gate: a dump restores into an empty database.*
5. **Seafile and Jellyfin.** Data migrations: a MariaDB dump for Seafile; jellystat's Postgres 18
   cluster moved as-is.
   *Gate: data cut over and checked; old stacks retired.*
6. **Remaining app VMs**, as chosen in F1.

**Open questions.**
- Agree with the order? Should portfolio come before the pilot, since it has no data at risk?

**Decision.** _open_

---

## Appendix: facts worth keeping

Found by the earlier work; each costs time to rediscover.

| Fact | Applies to |
|---|---|
| Docker 28+ with `gateway_mode_ipv4: isolated` on internal networks; without it containers on an "internal" network can still reach the host | every package |
| The Caddy binary carries a file capability (`cap_net_bind_service=ep`); a non-root Caddy with `cap_drop: [ALL]` needs `NET_BIND_SERVICE` kept just to exec | every sidecar |
| Postgres runs as `user: 70:70` (Alpine) with zero capabilities when its data dir is created empty and pre-owned | every Postgres |
| `pg_dump` refuses a server newer than itself: the dump service uses the server's exact tag | dumps |
| `pg_restore --list` reads only the table of contents; decode to `/dev/null` to verify a whole archive | dumps |
| Postgres 18 keeps data under `/var/lib/postgresql/18/docker`; mount `/var/lib/postgresql` | jellystat |
| Seafile: two-phase non-root boot; `bootstrap.py` never writes `SERVICE_URL`/`CSRF_TRUSTED_ORIGINS`; it needs `X-Forwarded-Proto: https` | seafile |
| `redis:7.4-alpine` is uid 999, gid 1000; with `user:` set it skips its root branch and needs no caps | seafile |
| The rclone image's entrypoint is `rclone`; `serve` binds 127.0.0.1 unless given `--addr :8080` | rclone services |
| rclone 1.75.0 is the floor for `serve restic` (CVE-2026-59733 private-repos bypass, CVE-2026-71309 path traversal) | restic-server |
| rclone does no SFTP host-key check unless `known_hosts_file` is set | restic-server |
| rest-server's default htpasswd path is on the data dir; set `PASSWORD_FILE` | restic-server |
| restic has no `RESTIC_REST_PASSWORD_FILE`; clients older than 0.13 break on append-only servers; an `http://` repo URL redirects and loses Basic auth | backups |
| resticprofile's `lock` is per container (a PID check), useless across `compose run`; rely on restic's repository lock | backup image |
| Retention must use `--keep-within` on append-only repositories | maintenance |
| oauth2-proxy does not trim a `*_FILE` secret; a trailing newline breaks Google sign-in | portfolio |
| Caddy discards inbound `X-Forwarded-*` unless `trusted_proxies` is set | every sidecar |
| SQLite must stay off NFS; Audiobookshelf binds :80 as non-root through Docker's default port sysctl | audiobookshelf |
| gluetun's firewall accepts inbound only from attached subnets; anything reaching Jellyfin shares a network with gluetun | jellyfin |
| A single-file bind mount stops following a file replaced by rename; recreate the container after editing | `.env`, secrets, htpasswd |
| Compose creates a missing bind source as a root-owned directory; use `create_host_path: false` | every bind |
| Compose `include:` files validate standalone and cannot name the parent's networks | compose layout |
| A `.env` is not a shell: `UID=$(id -u)` is stored literally | every `.env` |
| `intr` is ignored by the Linux NFS client since 2.6.25 | NFS volumes |

## Appendix: snapshot file map

On `backup-2026-11-20`; line counts in parentheses.

```
apps/_template/          7 files (691)   compose, backup compose, Caddyfile, app.meta.yaml, README, .env.example, scripts/dump-loop.sh
apps/audiobookshelf/     5 files (258)
apps/jellyfin/           5 files (572)
apps/portfolio/          8 files (1,450) as template, plus allowed-emails.example.txt; dump-loop.sh hardcodes its prefix
apps/restic-server/      5 files (537)
apps/seafile/            5 files (568)   no secrets/.gitkeep
global-caddy/            Caddyfile, Dockerfile, docker-compose.yml, .env.example, README.md, sites/ (35), ca/ (377 lines)
images/backup-sidecar/   Dockerfile, profiles.yaml, backup, README.md
.github/workflows/       backup-sidecar.yml
docs/adr/                0001 nested Caddy · 0002 multi-instance Global Caddy · 0003 hardening default
                         0004 authoring vs Docker host · 0005 wildcard DNS-01 · 0006 backup sidecar
docs/specs/              restic-server.md (586) · backup-sidecar.md (349)
AGENTS.md (CLAUDE.md symlink), CONTEXT.md, README.md, skills-lock.json
.agents/skills/ (39), .claude/skills/ (symlinks)
```
