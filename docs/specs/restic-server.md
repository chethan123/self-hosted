# Spec: restic-server

Status: **draft, pending review** · Owner: chethan · Supersedes: nothing · Related: ADR-0001, ADR-0002, ADR-0003, ADR-0005

A backup service that accepts restic backups from every app VM and writes them to three
independent storage targets, exposing each target as a path under one hostname.

---

## 1. Background

Every app package in this monorepo runs on its own Proxmox VM and keeps all state in a
co-located `volumes/` directory. `CLAUDE.md` says that directory "holds all app state — back it
up."

Backup capacity already exists on the network but not in this repo as a declared, reviewable
package. `global-caddy/sites/` routes two relevant hosts today:

| Route | Target | Status |
|---|---|---|
| `restic.{$BASE_DOMAIN}` | `10.1.1.200:80` | existing; its `apps/restic/` package was deleted in `b6d14a4` ("Removed restic to recreate") at the head of this branch |
| `backrest.{$BASE_DOMAIN}` | `10.1.1.250:9898` | existing Backrest (restic orchestrator UI), **unmodelled** |

More broadly, `global-caddy/sites/` carries ~33 host fragments against 3 app packages, so the
monorepo is mid-migration and most of the fleet is not yet modelled here.

**Decided:** this package is the **full replacement** for `restic.{$BASE_DOMAIN}`
(`10.1.1.200`). That host and its route fragment are retired; this service stands up at
`backup.{$BASE_DOMAIN}` / `10.1.1.100`. Backrest (`10.1.1.250`) is untouched by this spec — if it
currently drives backups into `10.1.1.200` it must be repointed, which belongs to the deferred
client-side work (§12).

The obvious shapes were considered and rejected:

- **Each app backs up to cloud storage directly.** Every app VM then holds delete-capable
  credentials for the backup destination. The machines most likely to be compromised are the
  ones that can erase the backups.
- **One repository, replicated.** Cheapest in bandwidth, but replication faithfully copies
  corruption and ransomware to every copy on the next scheduled run.
- **Mount cloud storage as a filesystem and write repositories onto it.** Requires the rclone
  Docker volume plugin, which needs `CAP_SYS_ADMIN`, `/dev/fuse` and host networking on the
  Docker daemon — a root-equivalent grant installed out-of-band and invisible to any compose
  file. It also inserts a writeback cache between "write returned OK" and "data is durable".

This service is the alternative: a gateway that speaks restic's REST protocol to clients and
talks to each storage backend natively, enforcing append-only at the edge that clients touch.

## 2. Goals

1. Every app package can back up to **three independent targets** with no shared failure.
2. Clients hold **no credential that can delete a backup**. Append-only is enforced by the
   server, not by client good behaviour.
3. An app package's backups are **isolated from other app packages** — one compromised app
   cannot read or write another's repositories.
4. Cloud storage credentials live on **one hardened VM**, never on app VMs.
5. The whole service is a **standard app package**: one directory, one compose stack, no
   host-*daemon* prerequisites — nothing installed outside compose, no Docker plugin, no
   host capability grants. It is not zero-setup: see §12.1 for the operator prerequisites
   that must exist before first start.

## 3. Non-goals

- **Client-side backup jobs.** What runs `restic backup` on each app VM is follow-on work,
  along with `apps/_template/` and `/onboard-app` changes.
- **The maintenance path.** Pruning and verification need a separate, normally-powered-off VM
  (§9). Designed here, built later — nothing can be pruned until repositories have history.
- **Observability.** No Prometheus, no freshness alerting yet. Called out as a real gap in §11.
- **Backing up this VM itself.** See §11.

## 4. Vocabulary

**Target** — one storage location behind one URL path. There are exactly three: `nfs`,
`rsync-net`, `pcloud`. A target is a place, not a repository.

**Repository** — one restic repository, owned by one app package, living on one target.
There are 3 × N of them. Addressed as `/<target>/<app-slug>/`.

**Maintenance path** — the out-of-band route to a repository that bypasses the append-only
HTTP endpoint and holds delete authority. Used only for `forget`, `prune`, `check`, `unlock`.

**Append-only endpoint** — the client-facing HTTP surface. Accepts new objects, refuses
overwrites and refuses deletes except lock files.

## 5. Architecture

```
app VM (jellyfin)  ─┐
app VM (seafile)   ─┼─ https ─> Global Caddy ─ HTTPS ─> Sidecar Caddy (10.1.1.100:443)
app VM (…)         ─┘         (public wildcard)   ^           │
                                                  └── internal CA, pinned (§8, D10)
                                                              │ handle_path strips prefix
                          ┌───────────────────────────────────┼────────────────────────┐
                          │                                   │                        │
                    /nfs/*│                        /rsync-net/*│              /pcloud/*│
                          v                                   v                        v
                   rest-server:8000              rclone-rsync-net:8080      rclone-pcloud:8080
                          │                                   │                        │
                   NFS named volume                    sftp: rsync.net           pcloud API
                   (kernel-mounted)                     (egress)                  (egress)
```

Three servers, not one, because the storage backends are different in kind. The NFS target is a
real POSIX filesystem, so `restic/rest-server` runs on it directly. The two cloud targets are
APIs, so `rclone serve restic` speaks restic's REST protocol on one side and the provider's API
on the other — with no filesystem, and therefore no cache, in between.

This is restic's own documented recommendation for backends that lack native append-only:
`doc/060_forget.rst` names `rclone serve restic` for exactly this purpose. The two are the same
protocol — restic's `rclone:` backend embeds its `rest:` backend
(`internal/backend/rclone/backend.go:33,285`).

## 6. How it is used

### Creating a repository

Repositories are created by the client, over the append-only endpoint. Neither server gates
repository creation on append-only mode (verified: `rclone cmd/serve/restic/restic.go:343-350`
vs `:424-433`; `rest-server repo/repo.go:766-797` has no append-only check).

```console
export RESTIC_REPOSITORY="rest:https://backup.{$BASE_DOMAIN}/nfs/jellyfin/"
export RESTIC_REST_USERNAME=jellyfin
export RESTIC_REST_PASSWORD=…        # environment only — restic has no *_FILE variant for the
                                     # REST login (internal/backend/rest/config.go:85-86)
export RESTIC_PASSWORD_FILE=/run/secrets/restic_password
restic init
```

**`https://`, and credentials in the environment — both matter.** The Global Caddy ends with
`http://{$BASE_DOMAIN}, http://*.{$BASE_DOMAIN} { redir https://{host}{uri} permanent }`. restic's
REST backend sets no `CheckRedirect`, and Go's client neither forwards URL userinfo to the
redirect target nor re-adds `Authorization`, so a `http://` repository URL yields a 401 that
restic treats as permanent — `init` fails on the first call, after the credential has already
crossed the LAN in cleartext. Userinfo in the URL also lands in `ps` output and shell history.

Note the trailing slash is supplied by restic itself (`internal/backend/rest/config.go:71-77`),
so a client never sends a bare `/nfs`. It matters only for hand-issued `curl`: `handle_path
/nfs/*` does not match bare `/nfs`, which falls through to the sidecar's 404.

### Backing up

```console
restic backup /data --tag nightly
```

Runs against all three targets by pointing `RESTIC_REPOSITORY` at each in turn. Three separate
uploads: there is no cross-target deduplication, by design (§7, D2).

### Restoring

```console
restic snapshots
restic restore latest --target /restore
```

Reads are unrestricted — append-only constrains writes and deletes only.

### What a client cannot do

`restic forget`, `restic prune` and `restic key remove` will fail with HTTP 403. This is
intended. Retention is the maintenance path's job (§9).

`restic unlock` **does** work: both servers exempt `locks/` from the delete ban
(`rclone restic.go:455-463`; `rest-server repo/repo.go:737-740`), and restic documents this
exemption explicitly (`cmd/restic/cmd_unlock.go:24`).

## 7. Design decisions

| # | Decision | Rationale |
|---|---|---|
| **D1** | `rclone serve restic` for cloud targets; **not** the rclone Docker volume plugin | The plugin needs `CAP_SYS_ADMIN` + `/dev/fuse` + host networking (`contrib/docker-plugin/managed/config.json`), granted out-of-band and invisible to compose. It also puts a VFS writeback cache under a repository, so `fsync`+`rename` complete against a local cache rather than the remote. `serve restic` has no VFS flags at all. |
| **D2** | Three **independent** repositories per app; no replication between targets | Replication propagates corruption and ransomware to every copy on the next run. Independent repositories share no failure. Cost: 3× upload, 3× storage, no cross-target dedup — accepted. |
| **D3** | **Append-only** on all three endpoints | The reason to run a backup server at all. A compromised app VM can add snapshots but cannot delete or overwrite history. |
| **D4** | Retention uses **`--keep-within`**, never `--keep-daily/weekly/monthly` | Append-only stops deletion but not *addition*. An attacker can inject snapshots timestamped just newer than the real ones, so a `--keep-weekly` policy prunes the legitimate ones and keeps theirs. restic documents this attack and prescribes `--keep-within` (`doc/060_forget.rst:395-445`). Binding on the maintenance path. |
| **D5** | Gateway for all three targets — cloud credentials on this VM | The alternative was clients talking to rsync.net directly behind an SSH forced command pinned to `rclone serve restic --stdio --append-only`. That cannot sit behind this gateway: such a channel carries restic's REST protocol over HTTP/2, while our `rclone serve restic` needs an *rclone remote* underneath it, and rclone's SFTP backend speaks SFTP. The protocols do not chain. (`server_command` is not a workaround — it selects which sftp-server binary to invoke, `backend/sftp/sftp.go:336-349`.) It would also put an rsync.net SSH key on every app VM, which is what D5 exists to avoid. Cost: credentials concentrate here (§10). |
| **D6** | One repository per **target × app package**, path `/<target>/<app-slug>/` | A restic repository password decrypts everything in that repository. A shared repository would let any app decrypt every other app's backups. Isolation beats cross-app dedup, which was never going to be large across unrelated datasets. |
| **D7** | **Backends own authentication**; Caddy passes `Authorization` through | Isolation is enforced by the process holding the data, not by a reverse-proxy matcher or by network topology. Username = app slug makes `--private-repos` enforce it for free. |
| **D8** | Maintenance runs on a **separate, normally-powered-off VM** | It needs every repository password and full storage credentials — a strict superset of everything else in this design. restic's phrase is "a separate and well-secured client" (`doc/060_forget.rst:416-419`). A machine with no listening services is a much smaller target. |
| **D10** | Sidecar terminates **TLS with Caddy's internal CA**, pinned by the Global Caddy | ADR-0001's plaintext hop carries every app's Basic credential here, on a segment the stated adversary shares. Let's Encrypt was considered and rejected: the sidecar is not internet-reachable, so DNS-01 would be required, which puts a Cloudflare zone-edit token — a domain-wide capability — on the host holding every backup. Both ends of this hop are ours, so a public CA adds nothing over a pinned internal one. §8. |
| **D9** | pcloud's rclone config is a **read-only file-secret**, exactly like rsync.net's | An earlier draft made it writable state in `volumes/` on the theory that OAuth refresh must persist. That was wrong twice. pcloud's stored token carries `"expiry":"0001-01-01T00:00:00Z"` (`docs/content/pcloud.md:65`), and `timeToExpiry` returns ~95 years for a zero expiry (`lib/oauthutil/oauthutil.go:412-421`) — the renewer is armed but never fires. Even if it did, `configfile.Save` writes via `os.CreateTemp(configDir,…)` + `os.Rename` (`fs/config/configfile/configfile.go:132,191,197`), which a single-file bind mount cannot satisfy: EROFS on the temp create under `read_only`, EBUSY renaming over the mount point. If a writable rclone config is ever genuinely needed, mount the *directory* and pass `--config /config/rclone.conf`. |

## 8. Component specification

### Services

| Service | `container_name` | Image | Networks | Egress | Runs as |
|---|---|---|---|---|---|
| `caddy` | `caddy-restic-server` | `caddy:2.8-alpine` | edge, frontend | yes (published port) | house default |
| `rest-server` | `rest-server` | `restic/rest-server:0.14.0` | frontend | **no** | `1000:1000` |
| `rclone-rsync-net` | `rclone-rsync-net` | `rclone/rclone:1.75.1` | edge, frontend | yes | `1000:1000` |
| `rclone-pcloud` | `rclone-pcloud` | `rclone/rclone:1.75.1` | edge, frontend | yes | `1000:1000` |

**rclone version floor: 1.75.0.** Two separate advisories land in exactly the code path this
design depends on — sub-path addressing and `--private-repos` isolation:

| CVE | Fixed in | What |
|---|---|---|
| `CVE-2026-59733` | v1.74.4 | `serve restic`: `--private-repos` isolation bypass (`changelog.md:405`) |
| `CVE-2026-71309` / `GHSA-45pq-889g-fcgh` | **v1.75.0** | `serve restic`: path traversal above the served directory (`changelog.md:173`), guarded by `iofs.ValidPath` at `restic.go:247-257` |

An earlier draft of this spec set the floor at 1.74.4 and attributed the `iofs.ValidPath` guard
to it. That was wrong: `git show v1.74.4:cmd/serve/restic/restic.go` contains no `iofs.ValidPath`;
v1.75.0 does. **Never pin below 1.75.0.**

`rest-server` is deliberately **not** on `edge`. NFS is mounted by the VM host's kernel and
bind-mounted in, so it works on an internal-only network.

### Service naming — recorded deviation

`CLAUDE.md` requires the app service to be named after the app slug, because that name is the
sidecar's `reverse_proxy` target. This package has **no slug-named service**: the slug is
`restic-server` and there are three upstreams, one per target. This mirrors `apps/jellyfin`,
which also fans out to several upstreams. `app.meta.yaml` carries a jellyfin-style `routes:`
extension naming each path and its upstream, plus an explicit note that the absence of a
slug-named service is intentional.

### Networks

`edge` (bridge) and `frontend` (`internal: true`). **No `backend` network** — this app has no
database. Recorded as a deviation in `app.meta.yaml`.

All three servers share `frontend`. Under D7 this is safe: reaching another service requires a
valid credential for it, so lateral movement buys nothing credentials do not already buy. This
stops being true if authentication ever moves to Caddy (see the fallback ladder below).

### Identity, UID/GID and NFS ownership

`rest-server` creates repository directories `0700` and objects `0600` (`repo/repo.go:50-56`);
`--group-accessible-repos` widens that to `0770`/`0660`. Neither image ships a non-root user —
`restic/rest-server:0.14.0` has no `USER` instruction and does not `chown /data`, and
`rclone/rclone` is `FROM alpine` with no `USER`.

Therefore, all three backend services run as **`1000:1000`**, and:

- the NFS export `/export/restic` must be owned `1000:1000` before first start;
- the export must not `root_squash` that UID into `nobody` — check `anonuid`/`anongid`;
- **the maintenance VM (§9) must use the same UID**, or the repositories must be created with
  `--group-accessible-repos` and both hosts must share the GID. Otherwise `prune` and `check`
  hit `EACCES` on every pack file.
- file-secrets are bind mounts that retain host permissions; each must be readable by UID 1000.

### Flags

`rest-server` — the image entrypoint always runs
`rest-server --path "$DATA_DIRECTORY" --htpasswd-file "$PASSWORD_FILE" $OPTIONS`
(`docker/entrypoint.sh:19`), so the htpasswd location is set through the **environment**, not
through `$OPTIONS`:

```yaml
environment:
  - PASSWORD_FILE=/run/secrets/htpasswd-nfs      # default is /data/.htpasswd — must override
  - OPTIONS=--append-only --private-repos
```

Without that override the entrypoint `touch`es an empty `.htpasswd` **on the NFS export**
(`entrypoint.sh:8-10`), logs "No user exists", and every request 401s.

`rclone serve restic`, both instances:

```
rclone serve restic --addr :8080 --append-only --private-repos \
  --htpasswd /run/secrets/htpasswd-<target> <remote>:<path>
```

**`--addr :8080` is load-bearing.** The default is `127.0.0.1:8080`
(`lib/http/server.go:136-139`) — left alone, the sidecar cannot reach the container at all.

`--baseurl` is unused: Caddy strips the prefix, so each backend sees its own root.
`--listen :8000` on rest-server is already the default (`main.go:50`) and is stated explicitly
only for readability.

### SSH host key verification — mandatory

rclone performs **no** host key validation when `known_hosts_file` is unset — it falls through to
`ssh.InsecureIgnoreHostKey()` with only a log notice (`backend/sftp/sftp.go:1363-1365`). Since
rsync.net's snapshots are the only backstop that survives compromise of this VM (§10), an
on-path attacker impersonating rsync.net would receive every upload and could serve a forged
repository.

The rsync.net remote therefore sets `known_hosts_file = /run/secrets/rsync-net.known_hosts`,
seeded from rsync.net's published host key. `--sftp-pin-host-key` is **not** a substitute: it is
trust-on-first-use and needs a writable config to persist the pin, which D9 rules out.

### Transport security — deviation from ADR-0001

ADR-0001 makes the Global Caddy → sidecar hop plain HTTP. **This app does not.** For every other
app that hop carries only that app's own traffic; here it carries *every* app's Basic credential,
and the stated adversary — a compromised app VM — shares the `10.1.1.0/24` segment. Left
plaintext, one compromised app could ARP-spoof the path and harvest every other app's backup
credential, defeating goal 3.

The sidecar therefore terminates TLS on **:443** using **Caddy's internal CA**:

```caddyfile
backup.{$BASE_DOMAIN} {
	tls internal
	...
}
```

and the Global-Caddy fragment pins it:

```caddyfile
@backup host backup.{$BASE_DOMAIN}
handle @backup {
	reverse_proxy https://10.1.1.100 {
		transport http {
			tls_trusted_ca_certs /etc/caddy/ca/backup-ca.crt
			tls_server_name backup.{$BASE_DOMAIN}
		}
	}
}
```

`tls internal` is in stock Caddy, so the sidecar stays on `caddy:2.8-alpine` — no xcaddy build,
no DNS module.

**Why not Let's Encrypt here.** The sidecar is not internet-reachable, so HTTP-01 and TLS-ALPN-01
are unavailable; DNS-01 would work but requires the xcaddy Cloudflare build *and* a Cloudflare
zone-edit token on this VM. That token is a domain-wide capability — a compromised backup host
could then hijack any subdomain — which is a strictly larger blast radius than the problem being
solved. The only client on this hop is the Global Caddy, and both ends are configured by us, so a
publicly-trusted CA buys nothing a pinned internal CA does not. LE stays on the Global Caddy,
where the token already lives (ADR-0005).

`tls_insecure_skip_verify` was rejected: it encrypts without authenticating, and an active
on-path attacker would simply present its own certificate.

**CA root distribution.** A CA *certificate* is public — only the key is secret, and it never
leaves the sidecar's `volumes/caddy`. The root is therefore **committed to `global-caddy/ca/`**
and reaches every Caddy VM through the sparse checkout they already do. Bootstrap and recovery
are in §12.1.

**Bootstrap ordering is a fleet-wide hazard, and the repo guards it.** The cert can only be
extracted *after* the sidecar first starts, but the Global Caddy config that pins it is committed
before that. Caddy fails its whole config load if `tls_trusted_ca_certs` names anything that is
not a readable certificate, so an early `git pull && docker compose up -d` on a Caddy VM would
take down every route on it. Two guards: `sites/backup.caddy` ships **commented out** until the
cert exists, and the mount is a *directory* (`./ca:/etc/caddy/ca:ro`) rather than a single file,
because Compose creates a missing bind-mount source as a directory — a single-file mount would
silently yield `backup-ca.crt/` and fail Caddy later.

### Routing

```caddyfile
handle_path /nfs/*        { reverse_proxy rest-server:8000 }
handle_path /rsync-net/*  { reverse_proxy rclone-rsync-net:8080 }
handle_path /pcloud/*     { reverse_proxy rclone-pcloud:8080 }
handle                    { respond "Service not found" 404 }
```

`handle_path` strips the matched prefix. **Path-based**, a deliberate deviation from the
host-matcher convention of ADR-0002 — three targets on one hostname were an explicit
requirement. ADR-0005's wildcard certificate is unaffected: one subdomain.

Verify at bring-up with one `curl -v` that `handle_path` preserves the trailing slash
(`/nfs/jellyfin/` → `/jellyfin/`); the traced behaviour below assumes it does.

### Authentication

Three htpasswd files, one per service, username = app slug, bcrypt.

`--private-repos` compares the authenticated username against the **first path segment after
prefix stripping** (`rclone restic.go:274-284`; `rest-server handlers.go:75-81`). Credential
`jellyfin` reaches `/nfs/jellyfin/…` and 401/403s elsewhere.

**Reload caveat.** Both servers reload htpasswd on the mtime of the mounted *inode*, but
`htpasswd(1)` writes temp-then-rename — so an edited file behind a **single-file** bind mount is
invisible until the container restarts. Either mount the directory or plan on a restart when
adding an app.

**Performance risk — measure at bring-up.** `rest-server` caches verified passwords for 60 s
(`htpasswd.go:50`). `rclone serve restic` has no cache: `--htpasswd` goes through
`goauth.HtpasswdFileProvider` (`lib/http/middleware.go:100-106`). A restic backup is thousands
of Basic-authenticated requests. Ordered fallbacks if bcrypt-per-request is prohibitive:

1. `{SHA}` entries in the two rclone htpasswd files (weaker hashing, internal-only network).
2. Caddy-side authentication with header-passed identity — `--user-from-header` on rclone and
   `--proxy-auth-username` on rest-server (`main.go:69`). This must be applied to **all three**
   services, and **only together with per-service frontend networks**
   (`frontend-nfs`/`frontend-rsync-net`/`frontend-pcloud`), because both servers then trust the
   header outright and any container sharing `frontend` could forge it.

`--user`/`--pass` is not an option: it precomputes one MD5Crypt hash for a **single** user
(`middleware.go:108-120`), which cannot express per-app identity.

### Volumes and secrets

| Path | Kind | Contents |
|---|---|---|
| NFS named volume → `/data` | NFS, **`rw`** | the `nfs` target's repositories |
| `./secrets/htpasswd-{nfs,rsync-net,pcloud}` | file-secret, `ro` | per-service credentials |
| `./secrets/rsync-net.key` | file-secret, `ro` | SSH key for the SFTP remote |
| `./secrets/rsync-net.known_hosts` | file-secret, `ro` | pinned rsync.net host key |
| `./secrets/rclone-rsync-net.conf` | file-secret, `ro` | static |
| `./secrets/rclone-pcloud.conf` | file-secret, `ro` | static — token does not expire (D9) |

`app.meta.yaml` records the NFS volume under `nfs_volumes` with `access: rw`, matching the `:rw`
mount suffix. This is one of the few `rw` NFS mounts in the fleet and is deliberate: it is the
repository store.

`read_only: true` on all three **backend** containers. The sidecar keeps the house default
(`read_only: false`, "not yet hardened") as in `apps/_template` and `apps/jellyfin`.

### Resource limits and tmpfs

Per ADR-0003, every service sets `mem_limit`, `cpus`, `pids_limit`, `cap_drop: [ALL]` and
`security_opt: [no-new-privileges:true]`. Starting values to be tightened by
`/harden-container`.

Both rclone services need **`tmpfs: [/tmp]`**: rclone's `--temp-dir` defaults to `/tmp`, and on a
read-only root filesystem any spooled write is `EROFS`. rest-server writes only under `--path`
(plus `--log`/`--cpu-profile`, neither used), so it needs no tmpfs.

### Healthchecks and startup

Both rclone backends dial their remote during `NewFs` — SFTP "to return errors early"
(`sftp.go:1638-1639`), pcloud via `FindRoot` (`pcloud.go:353`). If rsync.net or pcloud is
unreachable at `compose up`, the container exits and crash-loops, the sidecar returns 502 for
that path, and nothing reports it.

Each backend gets a healthcheck; an unauthenticated request expecting **401** is a serviceable
liveness probe for both servers. `depends_on` cannot express the NFS dependency — if the volume
fails to mount, `rest-server` will not start, and that is the correct behaviour.

## 9. Maintenance path (designed, built later)

Runs from a separate VM (D8), powered on for a window and shut down after. Reaches each
repository **around** the append-only endpoint:

| Target | Route |
|---|---|
| `nfs` | mount the same NFS export as **UID 1000**, use restic's `local` backend. rest-server uses restic's local layout and supports simultaneous local and HTTP access (`rest-server README:88`; restic `doc/030_preparing_a_new_repo.rst:232-234`) |
| `rsync-net` | `restic -r sftp:…` directly |
| `pcloud` | `restic -r rclone:pcloud:…` directly |

Per repository: `forget --keep-within <policy>` (D4), then `prune`, then `check`, with
`check --read-data-subset` on a rotation rather than full `--read-data` every run.

Scheduling constraints, both verified:

- `restic check` takes an **exclusive** lock (`cmd_check.go:245`) — it cannot overlap a backup.
- `prune` locks the repository; backups cannot complete during it (`doc/060_forget.rst:25-29`).

These hold only for *cooperative* clients — see §10 on client-deletable locks. Schedule
maintenance in a client-quiet window.

**Restart the two rclone containers after each maintenance window**, or run them with
`--cache-objects=false`. rclone caches listed objects by default and only refreshes the cache on
a List (`restic.go:388-399`); after out-of-band deletion or repacking, stale entries surface to
clients as 500s.

**pcloud credential escalation.** `prune` does not reclaim space on pcloud until trash is
emptied, and `rclone cleanup` requires the account **username and password**, not the OAuth
token (`backend/pcloud/pcloud.go:321,338-340,886`). That is a full-account credential, strictly
stronger than anything the serving VM holds — it belongs in the maintenance VM's threat model
and nowhere else.

## 10. Security model

### What this protects against

A **compromised app VM**. It holds one HTTP credential scoped to its own repositories, on an
append-only endpoint. It can add snapshots; it cannot delete or overwrite history, and it cannot
read or write another app's repositories.

### What it does not protect against

**Compromise of this VM.** It holds the rsync.net SSH key, the pcloud token and an `rw` NFS
mount. Root here can destroy all three targets. The only backstop that survives is rsync.net's
immutable ZFS snapshots — **unverified**, see §11. pcloud has no equivalent: trash, revisions and
Rewind are all user-reversible, and Rewind cannot recover a purged trash. Treat pcloud as a
third copy, not an immutable tier.

**Compromise of the maintenance VM** (once built) is total: every repository password, full
storage credentials, and the pcloud account password.

**Credential interception on the LAN — closed.** The Global Caddy → sidecar hop is TLS with a
pinned internal CA (§8), not plaintext as ADR-0001 otherwise prescribes. This is the one place
in the fleet where that hop carries cross-app secrets, which is why it deviates. The design does
**not** rely on VLAN isolation for goal 3.

**Availability isolation is not achieved.** Append-only permits unlimited *additions*. One
compromised app can exhaust the NFS export, the rsync.net quota or the pcloud quota and thereby
stop every other app's backups; both servers also allow unlimited sub-repositories beneath
`/<user>/` (rest-server to depth 2, `handlers.go:44-47`; rclone to any depth).
`rest-server --max-size` is a whole-tree quota, not per-repository (`quota/quota.go:26`), and
`rclone serve restic` has no equivalent. Goal 3 covers confidentiality and integrity, **not**
availability.

**Clients can delete lock files.** The `locks/` delete exemption that makes `restic unlock` work
also lets a hostile client remove a maintenance `prune`/`check` lock and start a backup
mid-prune. restic aborts on failed lock refresh, so this is a denial-of-maintenance, not a
corruption vector.

## 11. Risks and unverified assumptions

| Risk | Status |
|---|---|
| rsync.net ZFS snapshot immutability — the only backstop against compromise of this VM | **UNVERIFIED.** rsync.net is egress-blocked from the authoring environment; findings came from search-index summaries, not pages read. Verify before relying on it. |
| rsync.net host key must be obtained out of band | **ACTION REQUIRED.** Without `known_hosts_file`, rclone does no validation at all (`sftp.go:1363-1365`). |
| bcrypt-per-request on `rclone serve restic` | **UNMEASURED.** Fallbacks in §8. Measure at bring-up. |
| Global-Caddy→sidecar hop | **CLOSED** — TLS with a pinned internal CA (§8). Residual: if the sidecar's `volumes/caddy` is lost the CA regenerates and the root must be re-committed; until then the Global Caddy returns 502 for this host. Recovery in §12.1. |
| `rclone serve restic` does not verify uploaded objects | **VERIFIED** — straight to `RcatSize` (`restic.go:435`), no hash check, unlike rest-server (`repo/repo.go:601-613`). Narrower than it sounds: restic verifies blobs before sending (`repository.go:409-452`), so the gap is in-transit or at-server corruption over TLS; `check --read-data` catches it later. |
| Non-atomic writes on SFTP and pcloud | **VERIFIED** — both declare `PartialUploads: true`. An interrupted upload can leave a truncated pack under its final name; in append-only mode it can be neither overwritten (`restic.go:424-433`) nor deleted, so the maintenance path must remove it. The affected backup run fails immediately rather than retrying — restic treats 403 as permanent (`internal/backend/rest/rest.go:178-190`) — and the next run picks new pack IDs, so the repository is not wedged. |
| Stale rclone object cache after maintenance | **VERIFIED** — §9. Restart or `--cache-objects=false`. |
| No monitoring | **CLOSED on the client side** — every backup sidecar pushes one Uptime Kuma heartbeat per run (`docs/specs/backup-sidecar.md` D11). **OPEN on the server side**: nothing here notices a target that stops accepting writes for everyone. |
| htpasswd files hand-maintained across three services | **ACCEPTED for now.** Rots quickly — the fleet is ~33 routed services, not 3. The follow-on should derive them from `app.meta.yaml`. |
| Backrest (`10.1.1.250`) may still target the retired `10.1.1.200` | **OPEN** — repointing it belongs to the deferred client-side work (§12). |

## 12. Deferred work

1. ~~Client-side backup jobs; `apps/_template/` sidecar; `backup:` block in `app.meta.yaml`;
   `/onboard-app` step.~~ **Done** — ADR-0006, `docs/specs/backup-sidecar.md`; retrofits of the
   remaining packages are listed there (§11).
2. `apps/restic-maintenance/` — the VM from §9.
3. Generating the three htpasswd files and the maintenance schedule from declared intent.
4. Monitoring and freshness alerting.
5. Verifying the rsync.net claims in §11 and filling in real rsync.net values.

### 12.1 Operator prerequisites (before first start)

Goal 5 promises no host-*daemon* prerequisites, not zero setup. These must exist:

- NFS export `/export/restic` created and owned `1000:1000`, without squashing that UID.
- An SSH keypair registered with rsync.net, plus its host key captured for `known_hosts`.
- A pcloud OAuth grant obtained by running `rclone authorize` on a machine with a browser.
- Three htpasswd files generated (`htpasswd -B`).
- The Global-Caddy route fragment installed on every Caddy VM.
- **Sidecar CA bootstrap, in this order:** start the sidecar once; copy Caddy's internal root
  from `volumes/caddy/pki/authorities/local/root.crt` to `global-caddy/ca/backup-ca.crt`; commit
  it; **uncomment the block in `global-caddy/sites/backup.caddy`**; then reload on every Caddy
  VM with `docker exec caddy caddy reload --config /etc/caddy/Caddyfile`. **Reload, not
  `docker compose up -d`** — `./ca` and `./sites` are directory bind mounts, so neither the new
  certificate nor the uncommented fragment changes the Compose service definition, and `up -d`
  would find nothing to do and leave Caddy on its old config. Repeat all of it if the sidecar's
  `volumes/caddy` is ever lost — the CA regenerates and the old root stops matching, and this
  host 502s until the new one is redeployed.
- Retire `global-caddy/sites/restic.caddy` and decommission `10.1.1.200`.

## 13. Configuration values

| Key | Value |
|---|---|
| hostname | `backup` → `backup.{$BASE_DOMAIN}` (replaces `restic.{$BASE_DOMAIN}`) |
| VM IP | `10.1.1.100` (replaces `10.1.1.200`) |
| sidecar port | **`443`** — TLS terminates at the sidecar (§8), not 80 as elsewhere in the fleet |
| NFS server / export | `192.168.86.250:/export/restic` |
| backend UID:GID | `1000:1000` |
| pcloud region | US — `api.pcloud.com` |
| rsync.net | **placeholder** — real user, host, path and host key to be filled in |
| seeded app slugs | **placeholder** |
| minimum restic client | `>= 0.13` is a hard floor — lock refresh became create-new-then-delete-old in 0.13, which append-only requires. Pin a current release in practice. |
| Global route fragment | `global-caddy/sites/backup.caddy`, host-matcher form per ADR-0002 |
| Sidecar CA root | `global-caddy/ca/backup-ca.crt` — committed, public, bootstrapped per §12.1. The route fragment stays commented out until it exists. |

rsync.net requires paths with **no leading `/`** (`sftp.md:34-36`).

Nothing in the chain limits request body size; pack uploads are unbounded by design. rclone's
`--server-read-timeout`/`--server-write-timeout` default to 1 h each
(`lib/http/server.go:141-148`), bounding a single pack transfer — ample on a LAN.

## 14. References

Read from source, not from the web — `rclone.org` and `restic.net` are egress-blocked in the
authoring environment.

- rclone `v1.75.1` release / `1.76.0-dev` tree: `cmd/serve/restic/`, `backend/{sftp,pcloud}/`,
  `lib/http/`, `lib/oauthutil/`, `fs/config/configfile/`, `contrib/docker-plugin/managed/config.json`,
  `docs/content/`
- restic `0.19.1-dev`: `doc/060_forget.rst`, `doc/design.rst`, `doc/045_working_with_repos.rst`,
  `doc/REST_backend.rst`, `cmd/restic/`, `internal/`
- rest-server `0.14.0`: `README.md`, `handlers.go`, `repo/repo.go`, `htpasswd.go`, `Dockerfile`,
  `docker/entrypoint.sh`
- This repo: ADR-0001, ADR-0002, ADR-0003, ADR-0005, `CLAUDE.md`, `CONTEXT.md`,
  `global-caddy/`, `apps/_template/`, `apps/jellyfin/`
- **The superseded package**, `git show b6d14a4^:apps/restic/…` — worth reading before
  implementing. It independently reached the same `restic/rest-server:0.14.0` pin, `user:
  "1000:1000"`, `PASSWORD_FILE=/run/secrets/htpasswd`, `OPTIONS=--append-only --private-repos`,
  and a `storage_targets` schema in which one `path` is simultaneously the URL segment, the
  directory under `/data` and the htpasswd username. It differs in reaching cloud storage
  through host `rclone mount` FUSE units with `rshared` propagation — the approach D1 rejects —
  and its own compose comment records why: "Docker's create_host_path check can't catch an
  unmounted FUSE target — the mountpoint dir still exists, just empty — so without rshared,
  backups would silently land on local disk instead of pcloud." That is the D1 failure mode,
  observed in production rather than theorised.
