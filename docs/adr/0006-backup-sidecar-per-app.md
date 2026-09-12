# Every app package backs itself up through one house sidecar

Status: accepted · Related: ADR-0001, ADR-0003, ADR-0004, `docs/specs/restic-server.md` (§12 item 1)
· Mechanics: `docs/specs/backup-sidecar.md`

`CLAUDE.md` said "`volumes/` holds all app state — back it up" and left the *how* to whoever
deployed the VM. `restic-server` (`backup.{$BASE_DOMAIN}`) gave the fleet an append-only,
per-app-credentialed place to put backups and deferred the client side. This decides the client
side, once, for every package.

## Decisions

- **A sidecar per app, not a central puller.** A puller needs read access to every VM — a
  credential that unlocks the whole fleet on one host. A sidecar holds only its own app's
  credentials, which is exactly the compromised-app-VM model restic-server was designed around.
- **One self-built image, `ghcr.io/chethan123/backup-sidecar`**: upstream's resticprofile image
  (restic + rclone + resticprofile) plus `supercronic`, with the house profile baked in. The
  target list is in the image; a new restic-server target is an image bump, never an edit to N
  packages — each VM sparse-checks-out one package, so there is no shared file to import.
  Upstream's own scheduling is busybox `crond`, which needs root; supercronic runs as anyone.
- **Non-root, running as the account that owns the backup set.** Docker sets no ambient
  capabilities, so `cap_add` on a non-root `user:` grants nothing usable, and `no-new-privileges`
  blocks file capabilities; a sidecar that must read another UID's files is root or nothing.
  Root with `DAC_READ_SEARCH` was rejected: the identity rule of ADR-0003 holds, and the price —
  databases must be dumped rather than read live — is one we wanted anyway (below).
- **The backup set is the mount set.** Each package binds what it wants kept, read-only, under
  `/backup/<name>`; the sidecar backs up `/backup` and can see nothing else. No house default
  source list and no exclude syntax: what needs keeping depends on the app and how it is used.
- **Databases are never read live.** Every database — Postgres, MariaDB, SQLite — gets a dump
  service in its own engine's image writing into `volumes/dumps`; the datadir is never a source.
  A file-by-file copy of a live database taken over minutes is not a backup.
- **`docker-compose.backup.yml`, merged by `COMPOSE_FILE` in `.env`.** The sidecar (and the
  dump service) live in a second compose file; the app's own compose — often vendored from
  upstream — is never edited for backups. Same project, so networks, `depends_on` and bind paths
  just work.
- **Monitoring is one Uptime Kuma push per run** (`status=up` or `down`, naming the failed
  targets). No health logic in the container; a VM that is off is a missed heartbeat.
- **Every target, every app; one repository password per app; schedule per app.** Retention,
  `check` and `prune` stay where restic-server's spec put them: the maintenance VM.

## Consequences

- Reading anything is a per-package ownership decision: every file under a mounted source must
  be readable by the sidecar's UID, or the run fails (restic exit 3 is a failure here, on
  purpose). `secrets/` and `.env` *may* be backed up — the repository is encrypted — which makes
  the repository password the one secret that must be escrowed out of band.
- One more image to release from this repo (`.github/workflows/backup-sidecar.yml`) and to bump
  across packages.
- Nothing here has run on a VM (ADR-0004): `apps/portfolio/` is the reference package, statically
  validated, with its bring-up recorded in its README.
