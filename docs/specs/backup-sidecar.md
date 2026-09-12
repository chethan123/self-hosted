# Spec: backup-sidecar

Status: **accepted, reference package not yet brought up** · Owner: chethan · Decided by:
ADR-0006 · Related: ADR-0001, ADR-0003, ADR-0004, `docs/specs/restic-server.md`

The client half of the fleet's backups: a container in every app package that pushes that
app's state to every restic-server target on a schedule, and the rules a package follows to be
backed up correctly.

---

## 1. Background

`docs/specs/restic-server.md` stood up `backup.{$BASE_DOMAIN}`: three append-only, private-repo
targets (`/nfs`, `/rsync-net`, `/pcloud`), one Basic credential per app per target, and a
client that can add snapshots but never delete them. Its §12 deferred the client side — "backup
jobs; `apps/_template/` sidecar; `backup:` block in `app.meta.yaml`; `/onboard-app` step" — and
its §11 named the absence of monitoring the largest open gap. This spec closes both.

What exists today per package is a README line: "`volumes/` holds all state — snapshot/tar it."
Portfolio goes further with a `dump` service that writes a verified `pg_dump` into
`volumes/dumps` nightly and leaves collection to "whatever collects them". Nothing collects them.

## 2. Goals

1. Every app package ships its own backup, declared in the package, reviewable in the repo.
2. The same image and the same profile on every VM; per-app facts arrive as configuration.
3. Non-root, `cap_drop: [ALL]`, `read_only`, on the app's own VM, holding only that app's
   credentials — the hardening posture of ADR-0003 and the threat model of restic-server §10.
4. A database is never backed up by reading its files while it runs.
5. Every run reports once, to the monitoring the fleet already has.
6. An operator can restore from any target with the package's own tooling and nothing else.

## 3. Non-goals

- Retention, `check`, `prune`, repository repair — the maintenance VM (restic-server §9).
- Backing up NFS exports mounted into apps (media, libraries) — the NAS's job.
- Backing up the Global Caddy VMs — a wildcard certificate re-issues; nothing there is
  irreplaceable.
- Backrest (`10.1.1.250`) — unrelated to this standard; handled separately.
- Catch-up runs after downtime. A VM that is off during its window skips that run; the missed
  heartbeat is the alert.

## 4. Vocabulary

Added to `CONTEXT.md`:

- **Backup sidecar** — the `backup` service in a package's `docker-compose.backup.yml`, running
  the house image.
- **Backup set** — what the sidecar backs up: exactly the read-only binds under `/backup/`.
- **Dump service** — a per-database service, in the database engine's own image, that writes a
  verified dump into `volumes/dumps` so the sidecar never reads a live database.

## 5. Architecture

```
app VM (one package)                                              restic-server VM
┌────────────────────────────────────────────────────┐
│ docker-compose.yml         docker-compose.backup.yml│
│ ┌───────┐  ┌────┐          ┌──────┐   ┌───────────┐ │   https    ┌────────┐  /nfs/<slug>/
│ │ caddy │  │ db │◀─dump────│ dump │   │  backup   │─┼──────────▶│ Global │  /rsync-net/<slug>/
│ └───────┘  └────┘          └──┬───┘   │ (sidecar) │ │ (edge)     │ Caddy  │  /pcloud/<slug>/
│ ┌───────┐                     ▼       │           │ │            └────────┘
│ │ <app> │──▶ ./volumes/<x> ──────────▶│ /backup/x │ │
│ └───────┘    ./volumes/dumps ────────▶│ /backup/… │ │
│              ./secrets, ./.env ──:ro─▶│           │ │
└────────────────────────────────────────────────────┘
```

Two compose files, one project. The app's own file is never edited for backups; `COMPOSE_FILE`
in `.env` merges the second in, so `docker compose up -d` stays the command and `backup` can
reference the app's networks and `depends_on` its dump service.

The sidecar runs one image, `ghcr.io/chethan123/backup-sidecar` (`images/backup-sidecar/`):
upstream's resticprofile release image plus `supercronic`, with the house profile baked in. It
runs as the account that owns the backup set, reaches `backup.{$BASE_DOMAIN}` through the
package's egress network, and sees exactly the paths bound under `/backup`.

## 6. How it is used

### Onboarding a package (what `/onboard-app` does)

1. Decide the **backup set** — which `./volumes/<x>`, `./secrets`, `./.env` — and the
   **identity**: the one account that can read all of it. For a package with a dump service,
   that is the dump account.
2. Every database gets a **dump service** (§8); its datadir is never in the set.
3. Copy `apps/_template/docker-compose.backup.yml`, set `BACKUP_SLUG`, `user:`, the binds, the
   network that has egress, and the schedule. Add `COMPOSE_FILE=…` to `.env.example`.
4. Fill the `backup:` block in `app.meta.yaml` — the audit trail for all of the above.
5. On the VM: create the four file-secrets (below), `mkdir` + `chown` `volumes/backup-cache`
   and `volumes/dumps`, add the slug's three bcrypt lines on restic-server (its README,
   "Onboarding a new app"), create the Uptime Kuma push monitor, `docker compose up -d`.
6. Wait for the first dump to be published (`docker compose logs -f dump` until it reports the
   archive it wrote; the Postgres script dumps at boot when it has no recent success), then
   `docker compose run --rm --name backup-run backup run` once by hand; confirm the push landed;
   do one restore. The runner refuses an empty source directory, so a too-early first run fails
   rather than blessing an empty snapshot.

### Secrets

```bash
# The repository password. One per app; the three repositories hold the same data behind the
# same VM, so a key per target isolates nothing. ESCROW IT out of band — a backup whose key
# lived only on the VM it protects is noise once that VM is gone.
openssl rand -hex 32 > secrets/restic-password
# The REST login per target: username = slug (restic-server D7), password = the plaintext of
# the bcrypt line you add to that target's htpasswd file on restic-server.
for t in nfs rsync-net pcloud; do
  printf 'RESTIC_REST_USERNAME=%s\nRESTIC_REST_PASSWORD=%s\n' <slug> "$(openssl rand -hex 24)" \
    > secrets/backup-$t.env
done
chmod 0400 secrets/restic-password secrets/backup-*.env   # owned by the sidecar's account
```

### Restore

```bash
docker compose run --rm --name backup-snapshots backup -n nfs snapshots
mkdir restore && docker compose run --rm --name backup-restore -v ./restore:/restore \
  backup -n nfs restore latest --target /restore
```

`--name` is required: `container_name: backup` is fixed, and a bare `compose run` would try to
reuse the scheduled container's name and collide with it. Any target works the same
(`-n rsync-net`, `-n pcloud`). The restore lands owned by the sidecar's account: re-`chown` to
each service's UID before moving it into `volumes/`. Recommended, not enforced: one restore after
the first bring-up, and after every image bump. A restore may overlap a scheduled run: restic's
`restore` takes a read lock and `backup` an append lock, neither exclusive (`cmd/restic/lock.go`),
and the shared cache is written atomically; only `check` and `prune` are exclusive, and those never
run here (restic-server §9). The one thing a `compose run` is *not* serialized against is the
runner itself — there is no cross-container lock, by design (§8, the profile).

### One run by hand, other restic commands

```bash
docker compose run --rm --name backup-run backup run            # every target, then the Kuma push
docker compose run --rm --name backup-stats backup -n nfs stats # anything resticprofile accepts
```

## 7. Design decisions

| # | Decision | Rationale |
|---|---|---|
| **D1** | Sidecar per app, no central puller | A puller needs read access to every VM — one credential for the fleet on one host. A sidecar holds its own app's credentials only: restic-server §10's compromised-app-VM model, unchanged. |
| **D2** | One self-built image; the target list lives in it | Each VM sparse-checks-out one package; there is no shared file to import. Vendoring a profile into N packages rots (portfolio's `dump-loop.sh` already needs "re-vendor when upstream changes"). An image bump is one line per package. |
| **D3** | resticprofile for the restic side; **supercronic** for the schedule; one crontab line written by the entrypoint | resticprofile gives profiles, `env-file`, `password-file`, `initialize`, locks and a stable CLI for restore. Its own `schedule` command would write the same single line; upstream's image runs busybox `crond`, which needs root. |
| **D4** | **Non-root**, `user:` = the account owning the backup set | Docker never sets ambient capabilities (moby `daemon/oci_linux.go` → containerd `WithCapabilities`, no `Ambient`), and `no-new-privileges` blocks file capabilities: a non-root `user:` with `cap_add: [DAC_READ_SEARCH]` can read nothing extra. Root with that cap was rejected — ADR-0003's identity rule holds, and D6 removes the reason to want it. |
| **D5** | **The mount set is the backup set** — `:ro` binds under `/backup/<name>`, backed up as `/backup` | No house default and no exclude syntax: what is worth keeping is per app. The sidecar cannot back up what it cannot see, so the compose file *is* the declaration and `app.meta.yaml` mirrors it. `create_host_path: false` on every bind: a missing source stops `up` naming it, rather than backing up an empty directory. |
| **D6** | **Databases are dumped, never read live** — Postgres, MariaDB, SQLite alike | restic reads files over minutes; a datadir copied that way is not restorable in general. The dump runs in the engine's own image so `pg_dump`/`mariadb-dump`/`sqlite3` match the server (`pg_dump` refuses a newer server) — which is why the sidecar image carries no client tools. |
| **D7** | Every target, every app; order `nfs → rsync-net → pcloud`; each target its own resticprofile run | restic-server D2: three independent repositories, no replication. LAN copy first. Separate runs so one target's failure neither stops the others nor hides which one failed. |
| **D8** | One repository password per app; one REST credential per target; all four as file-secrets | D6 of restic-server isolates per app, not per target — the three repositories hold identical data behind one VM. restic has no `RESTIC_REST_PASSWORD_FILE` (`internal/backend/rest/config.go:85-86`), so the REST login is a dotenv file loaded by resticprofile's `env-file`. |
| **D9** | `secrets/` and `.env` **may** be in the backup set | The repository is encrypted; cloud targets hold ciphertext. Consequences carried by the standard: the repository password must be escrowed out of band (it cannot rescue itself); every file under a mounted source must be readable by the sidecar UID or the run fails; append-only + `--keep-within` means a rotated secret persists in old snapshots for the retention window — rotation is not purge; a non-root restore drops ownership. |
| **D10** | `docker-compose.backup.yml` + `COMPOSE_FILE` in `.env` — always, for every package | Uniform; the app's compose (often vendored, e.g. portfolio) is never touched. Same project, so networks and `depends_on` resolve. `include:` was rejected: included files validate standalone and cannot name the parent's networks. A separate project with `external:` networks loses `depends_on` and doubles the `up`. |
| **D11** | One Uptime Kuma push per run, `status=up` or `status=down&msg=failed:<targets>`; **no** in-container healthcheck | The fleet already alerts on missed heartbeats there; `status=down` turns a failure into an immediate alert rather than a deadline miss. Health logic in the container would be a second, unwatched monitor. |
| **D12** | Schedule per app, unconstrained; a committed default in `docker-compose.backup.yml`, overridable from `.env` | Frequency and window depend on the app's data and its dump timing (the dump must finish before the sidecar runs). Nothing here reserves a fleet window; the maintenance VM (restic-server §9) will have to be scheduled around the declared schedules in `app.meta.yaml`. |
| **D13** | An unreadable file fails the run | restic exit 3 (some files unreadable) is *not* softened with `no-error-on-warning`. A backup set the sidecar cannot fully read is a configuration error, and D11 makes it visible the same night. |

## 8. Component specification

### The image (`images/backup-sidecar/`)

`FROM ghcr.io/creativeprojects/resticprofile:0.33.1` + `apk add supercronic`; `profiles.yaml`
at `/etc/resticprofile/`; entrypoint `backup`. `ENV BACKUP_TARGETS="nfs rsync-net pcloud"`,
`RESTIC_CACHE_DIR=/cache`, `HOME=/tmp`. No `USER` — compose sets it. `linux/amd64`.
Released by `.github/workflows/backup-sidecar.yml` on a `backup-sidecar/v<semver>` tag as
`ghcr.io/chethan123/backup-sidecar:<semver>`; the package is public (nothing in the image is
secret; a private package would need a pull token on every VM).

**The base image declares `VOLUME /resticprofile`.** Left alone, every container gets an
anonymous volume there. The compose override mounts a tmpfs on it, which both suppresses that
and gives the sidecar its one writable scratch path for the crontab and resticprofile's lock.

### The profile (`profiles.yaml`)

`base` — `password-file: /run/secrets/restic-password`, `cache-dir: /cache`, `initialize: true`
(append-only permits `init`; restic-server §6), `backup: {source: [/backup], host: <slug>,
tag: [<slug>], exclude-caches: true, exclude: ["*.part"]}`. `--host` is set explicitly: a
container's hostname is not stable, and restic's snapshot identity keys on it. `*.part` is the
dump contract's staging name (below): a run that overlaps a slow dump must not capture a
half-written archive.

No resticprofile `lock:`. It would live in one container's private tmpfs and its staleness test
is a PID lookup (`lock/lock.go`, `process.PidExists`), so across containers — a `compose run`
beside the scheduled one — it is either invisible or wrongly "stale". Sequencing within a run is
the runner's; concurrency against the repository is restic's own lock.

`nfs`, `rsync-net`, `pcloud` — `inherit: base`; `repository:
rest:https://backup.{{ .Env.BASE_DOMAIN }}/<target>/{{ .Env.BACKUP_SLUG }}/`; `env-file:
[/run/secrets/backup-<target>.env]`. Verified with resticprofile 0.33.1 and restic 0.19.1:
`show` renders the repository, `env-file` values reach restic's environment (`run-before`
probe), and the rendered command is `restic backup --cache-dir=/cache --exclude-caches
--host=<slug> --password-file=… --repo=rest:https://backup.<domain>/<target>/<slug>/ --tag=<slug>
/backup`.

Deliberately absent: `one-file-system` (each `/backup/<name>` is its own mount and would be
skipped), `no-error-on-warning` (D13), `lock` (above), anything retention- or check-shaped (403 on
the server).

### The entrypoint (`backup`)

| Command | Does |
|---|---|
| `schedule` (default) | validates, writes `<BACKUP_SCHEDULE> /usr/local/bin/backup run` to `/resticprofile/crontab`, `exec supercronic -passthrough-logs` on it |
| `run` | validates, and refuses if any `/backup/<name>/` is an empty directory (a dump not yet run, a bind to nowhere — never something to snapshot and ping `up` for); for each target in `BACKUP_TARGETS`: `resticprofile -n <target> backup`; then one Kuma push — `up` with the elapsed time, or `down` naming the failed targets; exit 1 on any failure |
| anything else | `exec resticprofile -c /etc/resticprofile/profiles.yaml "$@"` — restore, snapshots, stats |

Validation refuses to start, naming the fault: uid 0; missing `BACKUP_SLUG`, `BASE_DOMAIN`,
`BACKUP_SCHEDULE`, `BACKUP_PING_URL`; any of the four secrets missing or unreadable as the
running uid; `/backup` empty; `/cache` not writable; (`schedule` only) `/resticprofile` not
writable.

`BACKUP_PING_URL` is Kuma's push URL. Its query (`?status=up&msg=OK&ping=`) is stripped and
rebuilt from the result, so a URL pasted verbatim from Kuma cannot send `status` twice. The
literal value `none` opts out explicitly; blank is an error.

supercronic skips a run whose predecessor is still going (its default) and validates the
expression at start — an invalid `BACKUP_SCHEDULE` exits the container, which
`restart: unless-stopped` makes visible in `docker compose ps`.

A container killed mid-run (a `compose down` past `stop_grace_period`) leaves a lock in the
repository it was writing. The next run clears it once it is older than `restic-stale-lock-age`
(2 h, `profiles.yaml`) — `unlock` is permitted on the append-only endpoints — and waits
`restic-lock-retry-after` (1 m) on a younger one.

### The compose override (`docker-compose.backup.yml`)

The `backup` service, canonical form in `apps/_template/docker-compose.backup.yml`:

| Field | Value | Why |
|---|---|---|
| `image` | `ghcr.io/chethan123/backup-sidecar:<pinned>` | ADR-0003 pinned tags |
| `container_name` | `backup` | house naming: service name verbatim |
| `user` | `"<uid>:<gid>"` — the backup set's owner; `${BACKUP_UID:?}:${BACKUP_GID:?}` when it is the operator's account | D4 |
| `networks` | the package's egress network only (`edge` in the house layout) | reaches Global Caddy; needs nothing else. It is not on `frontend`/`backend`. |
| `environment` | `BACKUP_SLUG`, `BASE_DOMAIN=${BASE_DOMAIN:?}`, `BACKUP_SCHEDULE=${BACKUP_SCHEDULE:-<default>}`, `BACKUP_PING_URL=${BACKUP_PING_URL:?}`, `TZ=UTC` | D12; UTC pinned so the cron field means one thing |
| `secrets` | `restic-password`, `backup-nfs.env`, `backup-rsync-net.env`, `backup-pcloud.env` — `file:` secrets from `./secrets/` | D8 |
| `volumes` | the backup set, long syntax, `read_only: true`, `create_host_path: false`; `./volumes/backup-cache:/cache` (`rw`, same `create_host_path: false`) | D5; the cache persists across restarts and never enters the set. **A single-file bind (`./.env`) stops following a file replaced by rename** — most editors do that — so after editing `.env`, `docker compose up -d --force-recreate backup` (plain `up -d` recreates only when a variable the service uses changed). Directory binds are unaffected. |
| `tmpfs` | `/tmp:size=64m`, `/resticprofile:size=1m` | `read_only: true` root; `/resticprofile` holds the crontab and masks the base image's `VOLUME` |
| hardening | `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `read_only: true`, `mem_limit`, `cpus`, `pids_limit: 256` | ADR-0003. restic's memory grows with repository size; the template's `512m` is a starting value. `pids.max` counts threads, and restic and resticprofile are Go binaries — 64 is not enough on a many-core VM |
| `depends_on` | the dump service, when there is one | ordering on `up` only; the schedule does the real ordering |

Compose file-secrets in a non-swarm project are bind mounts of the host file with the host's
ownership and mode: the four files must be readable by the sidecar's uid (`0400`, owned by it).
Being single-file binds, they stop following a file replaced by rename — which is how editors and
most secret tooling write. **Rotating any of the four (or `.env`) ends with
`docker compose up -d --force-recreate backup`**; until then the running sidecar authenticates
with the old value and fails. Same mechanism restic-server's README documents for its htpasswd
files.

### Identity and readability

The sidecar's uid must read **every** file under every mounted source (D13). The rule for a
package: pick the one account that owns the set, run the sidecar *and the dump service* as it,
and mount only what it can read. Where a service writes files another uid cannot read
(a `0700` datadir), that path is not in the set — its dump is. Where a file must be readable by
both its consumer and the sidecar (a `secrets/db_password.txt` read by postgres as uid 70),
own it by the consumer, group it to the sidecar's gid, `0640`.

### Dump service contract

Every database in a package has one. Requirements, all met by `apps/_template/scripts/dump-loop.sh`
(the Postgres implementation, vendored from portfolio):

1. Runs in the database engine's own image, **at the same tag as the server**.
2. Runs as the backup set's owner, never root, on the `backend` network only.
3. Writes into `volumes/dumps` atomically (a `*.part` staging name, then rename on the same
   filesystem — the profile excludes `*.part`, so a run overlapping a slow dump captures only
   published archives), `0640`, and **verifies** the archive whole before publishing it.
4. Applies its own retention (`DUMP_KEEP_DAYS`) — the dumps directory is a hand-off window, not
   history; history is the repositories.
5. Runs **before** the sidecar's schedule with room to finish; the datadir is never in the set.
   Its `/tmp` is a sized tmpfs like every other service's (ADR-0003).

MariaDB and SQLite implementations arrive with the first packages that need them (seafile;
jellyfin/audiobookshelf); they meet the same five points.

### Monitoring

One Uptime Kuma **push** monitor per app, heartbeat interval = the app's schedule plus grace.
`up` carries `msg=ok <seconds>s`; `down` carries `msg=failed:<targets>`. The push travels the
same egress path as the backup; a VM with no egress reports nothing, which is the alert.

## 9. Security model

**What a compromised app VM can do** — unchanged from restic-server §10: add snapshots to its
own three repositories; nothing to anyone else's; delete nothing. The sidecar adds no credential
that reaches beyond the app: three REST logins scoped to `<slug>` and one repository password.

**What this VM's backups expose if the repository password leaks**: everything in the set,
including `secrets/` and `.env` where a package chose to include them (D9), for as long as
those snapshots exist. That is the trade the encrypted repository buys; it is why the password
is a file-secret, `0400`, and escrowed rather than written anywhere else.

**The sidecar reads the whole set.** It is one more process on the VM that can read the app's
secrets — as the same uid that already can. It holds no write path to the app: every source is
`:ro`, the root filesystem is read-only, its only writable paths are its cache and a 1 MB tmpfs.

**Egress.** The sidecar is on the package's egress network and can reach anything the network
allows — the house layout's `edge` is a plain bridge. It contacts two hosts:
`backup.{$BASE_DOMAIN}` and the Kuma push URL. Narrowing that is per-package work.

**A restore is a write.** `compose run … restore` runs as the sidecar's account into a directory
the operator bound; nothing in the standard restores into `volumes/` unattended.

## 10. Risks and unverified assumptions

| Risk | Status |
|---|---|
| Nothing has run on a VM | **OPEN.** The image has not been built (no registry egress from the authoring environment); the profile and entrypoint were exercised with the real 0.33.1/0.19.1 binaries against dummy secrets; both compose files render with `docker compose config`. ADR-0004: bring-up is on the VM. |
| restic memory on large sets | **UNMEASURED.** `mem_limit: 512m` is a starting value; a package with a multi-GB set (seafile) will need to measure. |
| The repository password is on the VM it protects | **BY DESIGN**, mitigated by escrow (D9). The standard cannot check that escrow happened. |
| One egress network for backup + monitoring | **ACCEPTED.** See §9; a per-package `egress` allow-list is out of scope. |
| Uptime Kuma `status=down` semantics | **UNVERIFIED** against the fleet's Kuma version: push monitors have accepted `status=down` since 1.x; if a version ignores it, a failure is still caught by the missed heartbeat. |
| restic-server's client example | **FIXED** in this change: it named `RESTIC_REST_PASSWORD_FILE`, which restic does not have. |

## 11. Deferred work

1. Retrofits: seafile (MariaDB dump), jellyfin (SQLite dump + jellystat Postgres), audiobookshelf
   (SQLite dump), restic-server itself (its sidecar CA in `volumes/caddy`).
2. MariaDB and SQLite dump implementations, with those retrofits.
3. Deriving restic-server's three htpasswd files from the fleet's `app.meta.yaml` `backup:` blocks
   (restic-server §12 item 3).
4. A maintenance-window check against the declared schedules (restic-server §9).
5. Narrowing the sidecar's egress to the two hosts it needs.

## 12. Configuration values

| Key | Value |
|---|---|
| image | `ghcr.io/chethan123/backup-sidecar:1.0.0` — first release, tag `backup-sidecar/v1.0.0` |
| base image | `ghcr.io/creativeprojects/resticprofile:0.33.1` |
| targets | `nfs rsync-net pcloud` (image `ENV BACKUP_TARGETS`) |
| repository URL | `rest:https://backup.{$BASE_DOMAIN}/<target>/<slug>/` |
| secrets | `secrets/restic-password`, `secrets/backup-{nfs,rsync-net,pcloud}.env` |
| set root / cache / scratch | `/backup` / `/cache` (`./volumes/backup-cache`) / `/resticprofile` (tmpfs) |
| schedule | per app; `BACKUP_SCHEDULE`, cron, UTC |
| monitoring | `BACKUP_PING_URL`, Uptime Kuma push, one per run |
| minimum restic client | 0.19.1 as bundled; restic-server's floor is 0.13 |

## 13. References

- This repo: ADR-0001, ADR-0003, ADR-0004, ADR-0006, `docs/specs/restic-server.md`,
  `apps/_template/`, `apps/portfolio/`, `images/backup-sidecar/`
- resticprofile `v0.33.1`: `config/profile.go` (`env-file`, `lock`, `initialize`, `no-error-on-warning`),
  `config/global.go`, `docs/content/installation/docker.md`,
  `docs/content/schedules/non-root-schedule-in-container.md`, `build/Dockerfile`, `.goreleaser.yml`
- restic `v0.19.1`: `internal/backend/rest/config.go` (REST credentials from the environment only)
- moby (2026-09): `daemon/oci_linux.go` `WithCapabilities` — no ambient set for any user
- supercronic: `-test`, `-passthrough-logs`, overlap skipping by default
