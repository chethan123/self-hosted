# Spec: restic-server

Status: **draft, pending review** · Owner: chethan · Supersedes: nothing · Related: ADR-0001, ADR-0002, ADR-0003, ADR-0005

A backup service that accepts restic backups from every app VM and writes them to three
independent storage targets, exposing each target as a path under one hostname.

---

## 1. Background

Every app package in this monorepo runs on its own Proxmox VM and keeps all state in a
co-located `volumes/` directory. `CLAUDE.md` says that directory "holds all app state — back it
up." Nothing in the repo currently does. Backups are the one piece of the platform that has to
work on the day everything else has failed, and today they do not exist as a first-class,
declared, reviewable thing.

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
5. The whole service is a **standard app package**: one directory, one compose stack,
   `cp .env.example .env && docker compose up`. No host-level prerequisites.

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
app VM (seafile)   ─┼─ https ─> Global Caddy ─ http ─> Sidecar Caddy (10.1.1.100:80)
app VM (…)         ─┘            (TLS, ADR-0001)              │
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
export RESTIC_REPOSITORY="rest:http://jellyfin:PASSWORD@backup.{$BASE_DOMAIN}/nfs/jellyfin/"
export RESTIC_PASSWORD_FILE=/run/secrets/restic_password
restic init
```

The trailing slash is required — both servers dispatch on it to distinguish "list/create a
repository" from "fetch an object".

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
| **D5** | Gateway for all three targets — cloud credentials on this VM | Alternative was clients talking to rsync.net directly behind an SSH forced command. Not constructible behind a gateway: rclone's `server_command` selects an SFTP server binary (`backend/sftp/sftp.go:336-349`) and cannot speak to a forced command running `rclone serve restic --stdio`. Keeps credentials off app VMs at the cost of concentrating them here (§10). |
| **D6** | One repository per **target × app package**, path `/<target>/<app-slug>/` | A restic repository password decrypts everything in that repository. A shared repository would let any app decrypt every other app's backups. Isolation beats cross-app dedup, which was never going to be large across unrelated datasets. |
| **D7** | **Backends own authentication**; Caddy passes `Authorization` through | Isolation is enforced by the process holding the data, not by a reverse-proxy matcher or by network topology. Username = app slug makes `--private-repos` enforce it for free. |
| **D8** | Maintenance runs on a **separate, normally-powered-off VM** | It needs every repository password and full storage credentials — a strict superset of everything else in this design. restic's phrase is "a separate and well-secured client" (`doc/060_forget.rst:416-419`). A machine with no listening services is a much smaller target. |
| **D9** | pcloud's rclone config is **writable state in `volumes/`**, seeded from `secrets/` | pcloud is a real OAuth2 remote with a token renewer (`backend/pcloud/pcloud.go:173,344`). A read-only config means refreshed tokens cannot persist and the target dies silently at expiry. A self-rotating credential is state, not a static secret. Deviation from the file-secrets convention, recorded in `app.meta.yaml`. |

## 8. Component specification

### Services

| Service | `container_name` | Image | Networks | Egress |
|---|---|---|---|---|
| `caddy` | `caddy-restic-server` | `caddy:2.8-alpine` | edge, frontend | yes (published port) |
| `rest-server` | `rest-server` | `restic/rest-server:0.14.0` | frontend | **no** |
| `rclone-rsync-net` | `rclone-rsync-net` | `rclone/rclone:1.75.1` | edge, frontend | yes |
| `rclone-pcloud` | `rclone-pcloud` | `rclone/rclone:1.75.1` | edge, frontend | yes |

`rclone/rclone` is pinned at or above **1.75.1**. Anything below **1.74.4** is unacceptable:
sub-path routing had a path-traversal vulnerability (CVE-2026-59733 / GHSA-fqj9-69pf-6pjg) fixed
there, now guarded by `iofs.ValidPath` at `restic.go:247-257`. This design is entirely
sub-path-addressed.

`rest-server` is deliberately **not** on `edge`. NFS is mounted by the VM host's kernel and
bind-mounted in, so it works on an internal-only network.

### Networks

`edge` (bridge) and `frontend` (`internal: true`). **No `backend` network** — this app has no
database. Recorded as a deviation from the three-network model in `app.meta.yaml`.

All three servers share `frontend`. Under D7 this is safe: reaching another service requires a
valid credential for it, so lateral movement buys nothing that credentials do not already buy.

### Flags

`rest-server` — the image entrypoint always supplies `--path $DATA_DIRECTORY` and
`--htpasswd-file $PASSWORD_FILE`; everything else goes through `$OPTIONS`:

```
OPTIONS="--append-only --private-repos --listen :8000"
```

`rclone serve restic`, both instances:

```
rclone serve restic --addr :8080 --append-only --private-repos \
  --htpasswd /run/secrets/htpasswd <remote>:<path>
```

**`--addr :8080` is load-bearing.** The default is `127.0.0.1:8080`
(`lib/http/server.go:138-140`) — left alone, the sidecar cannot reach the container at all.

`--baseurl` is not used: Caddy strips the prefix before proxying, so each backend sees its own
root.

### Routing

```caddyfile
handle_path /nfs/*        { reverse_proxy rest-server:8000 }
handle_path /rsync-net/*  { reverse_proxy rclone-rsync-net:8080 }
handle_path /pcloud/*     { reverse_proxy rclone-pcloud:8080 }
handle                    { respond "Service not found" 404 }
```

`handle_path` strips the matched prefix. This is **path-based**, a deliberate deviation from the
host-matcher convention in ADR-0002 — three targets on one hostname were an explicit
requirement. The wildcard certificate arrangement of ADR-0005 is unaffected: one subdomain,
`backup.{$BASE_DOMAIN}`.

### Authentication

Three htpasswd files, one per service, username = app slug, bcrypt.

`--private-repos` compares the authenticated username against the **first path segment after
prefix stripping** (`rclone restic.go:274-284`; `rest-server handlers.go:75-81`). Credential
`jellyfin` therefore reaches `/nfs/jellyfin/…` and returns 401/403 for anything else.

**Performance risk, must be measured at bring-up.** `rest-server` caches password verification
for 60 s (`htpasswd.go:50`). `rclone serve restic` has no equivalent cache — `--htpasswd` goes
through `goauth.HtpasswdFileProvider` (`lib/http/middleware.go:101-106`). A restic backup is
thousands of HTTP requests, each carrying Basic auth. If bcrypt-per-request proves prohibitive,
the ordered fallbacks are: SHA1 entries in the two rclone htpasswd files, then Caddy-side
authentication with `--user-from-header` **and** per-service frontend networks. Not the latter
without the network split.

`--user`/`--pass` is not an option: it precomputes one MD5Crypt hash for a **single** user
(`middleware.go:109-120`), which cannot express per-app identity.

### Volumes and secrets

| Path | Kind | Contents |
|---|---|---|
| NFS named volume → `/data` | NFS, `rw` | the `nfs` target's repositories |
| `./secrets/htpasswd-{nfs,rsync-net,pcloud}` | file-secret, `ro` | per-service credentials |
| `./secrets/rsync-net.key` | file-secret, `ro` | SSH key for the SFTP remote |
| `./secrets/rclone-rsync-net.conf` | file-secret, `ro` | static, no token to refresh |
| `./volumes/rclone-pcloud/rclone.conf` | bind mount, `rw` | **writable** — OAuth token (D9) |

`read_only: true` holds on every container: a writable bind mount is independent of the root
filesystem.

### Known image constraints

`restic/rest-server:0.14.0` ships **no `USER` instruction and runs as root**, and does not
`chown /data`. ADR-0003 requires non-root, so `user:` must be set and the NFS export's ownership
must match. The binary is static and CGO-free, so an arbitrary UID works provided `/data` is
writable by it.

`--path` defaults to `/tmp/restic`; the image sets `DATA_DIRECTORY=/data`, so the documented
"all backups will be lost" trap does not apply here — but it is why `--path` must never be
hand-overridden.

## 9. Maintenance path (designed, built later)

Runs from a separate VM (D8), powered on for a window and shut down after. Reaches each
repository **around** the append-only endpoint:

| Target | Route |
|---|---|
| `nfs` | mount the same NFS export, use restic's `local` backend. rest-server uses restic's local layout and supports simultaneous local and HTTP access (`rest-server README:88`, echoed at restic `doc/030_preparing_a_new_repo.rst:232-234`) |
| `rsync-net` | `restic -r sftp:…` directly |
| `pcloud` | `restic -r rclone:pcloud:…` directly |

Per repository: `forget --keep-within <policy>` (D4), then `prune`, then `check`, with
`check --read-data-subset` on a rotation rather than full `--read-data` every run.

Scheduling constraints, both verified:

- `restic check` takes an **exclusive** lock (`cmd_check.go:245`) — it cannot overlap a backup.
- `prune` locks the repository; backups cannot complete during it
  (`doc/060_forget.rst:25-29`).

At 3 × N repositories this needs a real schedule, not a nightly loop.

**pcloud caveat:** deleted objects go to trash, retained by plan tier, so `prune` does not
reclaim space until trash is emptied. `rclone cleanup` can do it but requires username and
password in the config, not just the OAuth token
(`backend/pcloud/pcloud.go:321,338-340,886`).

## 10. Security model

### What this protects against

A **compromised app VM**. It holds one HTTP credential scoped to its own repositories, on an
append-only endpoint. It can add snapshots; it cannot delete or overwrite history, and it cannot
touch another app's repositories or decrypt them.

### What it does not protect against

**Compromise of this VM.** It holds the rsync.net SSH key, the pcloud OAuth token, and an `rw`
NFS mount. Root here can destroy all three targets. Mitigations, in order of strength:

1. rsync.net's immutable ZFS snapshots, which the credential holder reportedly cannot alter.
   **This claim is unverified** (§11) and is the only backstop that survives root on this VM.
2. pcloud has **no equivalent**. Its trash, revisions and Rewind are all user-reversible, and
   Rewind cannot recover a purged trash. Treat pcloud as a third copy, not as an immutable tier.
3. The NFS target has whatever the NFS server itself provides. Out of scope here.

**Compromise of the maintenance VM** (once built) is total: it holds every repository password
and full storage credentials. This is why it does not run continuously (D8).

**Quota exhaustion.** Append-only permits unlimited *additions*. A compromised app can fill a
target. `rest-server --max-size` exists but is a whole-tree quota, not per-repository
(`quota/quota.go:26`); `rclone serve restic` has no equivalent.

## 11. Risks and unverified assumptions

| Risk | Status |
|---|---|
| rsync.net ZFS snapshot immutability — the only backstop against VM compromise | **UNVERIFIED.** rsync.net is egress-blocked from the authoring environment; findings came from search-index summaries, not pages read. Verify before relying on it. |
| bcrypt-per-request on `rclone serve restic` | **UNMEASURED.** Real risk, fallbacks specified in §8. Measure at bring-up. |
| `rclone serve restic` does not verify uploaded objects | **VERIFIED** — streams straight to `RcatSize` (`restic.go:435`), no hash check, unlike rest-server (`repo/repo.go:601-613`). Narrower than it sounds: restic verifies blobs before sending (`repository.go:409-452`), so the gap is in-transit or at-server corruption over TLS. `check --read-data` catches it later. |
| Non-atomic writes on SFTP and pcloud | **VERIFIED** — both declare `PartialUploads: true`. An interrupted upload can leave a truncated pack under its final name. Compounding trap: in append-only mode it cannot be healed by re-upload (`restic.go:424-433`) and cannot be deleted — the maintenance path must remove it. |
| No monitoring | **OPEN.** A backup system that stops silently is worse than none. Deferred with the client-side work; this is the largest known gap. |
| This VM's own `volumes/` is not backed up | **OPEN.** Contains the pcloud OAuth token. Losing it means re-authorising pcloud, not losing data. |
| htpasswd files hand-maintained across three services | **ACCEPTED for now.** Rots around the fourth app. The follow-on should derive them from `app.meta.yaml`. |

## 12. Deferred work

1. Client-side backup jobs; `apps/_template/` sidecar; `backup:` block in `app.meta.yaml`;
   `/onboard-app` step.
2. `apps/restic-maintenance/` — the VM from §9.
3. Generating the three htpasswd files and the maintenance schedule from declared intent.
4. Monitoring and freshness alerting.
5. Verifying the rsync.net claims in §11 and filling in real values for the rsync.net remote.

## 13. Configuration values

| Key | Value |
|---|---|
| hostname | `backup` → `backup.{$BASE_DOMAIN}` |
| VM IP | `10.1.1.100` |
| sidecar port | `80` |
| NFS server / export | `192.168.86.250:/export/restic` |
| pcloud region | US — `api.pcloud.com` |
| rsync.net | **placeholder** — real user, host and path to be filled in |
| seeded app slugs | **placeholder** — real slugs to be filled in |

rsync.net requires paths with **no leading `/`** (`sftp.md:34-36`).

## 14. References

Read from source, not from the web — `rclone.org` and `restic.net` are egress-blocked in the
authoring environment.

- rclone `v1.75.1` release / `1.76.0-dev` tree: `cmd/serve/restic/`, `backend/{sftp,pcloud}/`,
  `lib/http/`, `contrib/docker-plugin/managed/config.json`, `docs/content/`
- restic `0.19.1-dev`: `doc/060_forget.rst`, `doc/design.rst`, `doc/045_working_with_repos.rst`,
  `doc/REST_backend.rst`, `cmd/restic/`, `internal/`
- rest-server `0.14.0`: `README.md`, `handlers.go`, `repo/repo.go`, `htpasswd.go`, `Dockerfile`
- This repo: ADR-0001, ADR-0002, ADR-0003, ADR-0005, `CLAUDE.md`, `CONTEXT.md`,
  `apps/_template/`, `apps/jellyfin/`
