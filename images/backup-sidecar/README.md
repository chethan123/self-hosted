# backup-sidecar

The one backup image every app package runs (ADR-0006; full design in
`docs/specs/backup-sidecar.md`). Published as `ghcr.io/chethan123/backup-sidecar:<version>` by
`.github/workflows/backup-sidecar.yml`; app packages pin the tag in `docker-compose.backup.yml`.

| Piece | What |
|---|---|
| `Dockerfile` | `ghcr.io/creativeprojects/resticprofile:0.33.1` (restic + rclone + resticprofile) + `supercronic` |
| `profiles.yaml` | the house profile: one resticprofile profile per restic-server target, templated from env |
| `backup` | the entrypoint — `schedule` (the service), `run` (one run + Kuma push), or passthrough to resticprofile |

## Contract with an app package

Runtime inputs, all set by the app's `docker-compose.backup.yml`:

| Input | Kind | Meaning |
|---|---|---|
| `BACKUP_SLUG` | env | app slug — repository path segment and REST username (restic-server D6/D7) |
| `BASE_DOMAIN` | env | repositories live at `rest:https://backup.$BASE_DOMAIN/<target>/<slug>/` |
| `BACKUP_SCHEDULE` | env | five-field cron, UTC — this app's choice |
| `BACKUP_PING_URL` | env | Uptime Kuma push URL (query stripped and rebuilt), or `none` |
| `/run/secrets/restic-password` | file-secret | the repository password — one per app, **escrowed out of band** |
| `/run/secrets/backup-<target>.env` | file-secret | dotenv: `RESTIC_REST_USERNAME=<slug>` + `RESTIC_REST_PASSWORD=…`, one per target |
| `/backup/<name>` | `:ro` binds | the backup set — the sidecar backs up `/backup` and sees nothing else |
| `/cache` | `rw` bind | restic's cache (`./volumes/backup-cache`), owned by the sidecar's UID |
| `/resticprofile` | tmpfs | crontab + resticprofile's lock; also masks the base image's `VOLUME` |
| `user:` | compose | the account owning every path under `/backup` — never root |

Targets are the image's `BACKUP_TARGETS` (`nfs rsync-net pcloud`), matching the profiles in
`profiles.yaml`. Adding one = a profile here, a name there, one credential file per VM, a bump.

## Release

```bash
git tag backup-sidecar/v1.0.0 && git push origin backup-sidecar/v1.0.0
```

The workflow builds `linux/amd64`, smoke-tests the entrypoint as a non-root user, and pushes
`ghcr.io/chethan123/backup-sidecar:1.0.0`. **After the first push, set the package to public**
(GitHub → Packages → backup-sidecar → Package settings → Change visibility): the repo is private,
so the package starts private, and every app VM would otherwise need a `docker login ghcr.io`
token to pull. Nothing in the image is secret — no domain, no address, no credential.

Pull requests touching this directory build the image and run the smoke test without pushing.

## Local check without Docker

`resticprofile -c profiles.yaml -n nfs show` with the four inputs above in the environment renders
the exact restic command the sidecar will run. `supercronic -test <crontab>` validates a schedule.
