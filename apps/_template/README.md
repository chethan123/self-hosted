# <app-name>

_What this app is, why you run it, and any quirks worth remembering. Free-form notes live here._

- **URL:** https://<hostname>.<your-domain>
- **VM / static IP:** <vm-name> / 10.0.0.42
- **Upstream:** <link to the app's project / image docs>

## Deploy
```bash
# on the app VM (sparse-checkout this app dir), as the NON-ROOT account that will own the backups
cp .env.example .env                     # fill in real values; BACKUP_UID/GID = `id -u` / `id -g`
mkdir -p volumes/app volumes/dumps volumes/backup-cache && chmod 0750 volumes/dumps
echo -n '<db-password>' > secrets/db_password.txt && chmod 0640 secrets/db_password.txt
# 0640, owned by you: db's entrypoint reads it as root (DAC_OVERRIDE) and the sidecar as BACKUP_UID.
# Every file under a mounted source must be readable by BACKUP_UID, or the run fails (spec D13).

# backups (docs/specs/backup-sidecar.md §6): one repository password — ESCROW IT — and one REST
# login per target, whose bcrypt lines you add on restic-server (its README, "Onboarding a new app")
openssl rand -hex 32 > secrets/restic-password
for t in nfs rsync-net pcloud; do
  printf 'RESTIC_REST_USERNAME=%s\nRESTIC_REST_PASSWORD=%s\n' <app-name> "$(openssl rand -hex 24)" > secrets/backup-$t.env
done
chmod 0400 secrets/restic-password secrets/backup-*.env

docker compose up -d                     # both files — COMPOSE_FILE in .env
docker compose run --rm backup run       # first backup by hand; check the Kuma monitor went up
```

## Notes
- Egress: <needs internet? why>
- Hardening deviations: <anything flipped off read_only, extra caps, and why>
- Backups: what `docker-compose.backup.yml` binds under `/backup` (and `app.meta.yaml`'s
  `backup:` block lists) — and nothing else. <what is NOT kept and why: caches, NFS media, …>.
  Restore: `docker compose run --rm -v ./restore:/restore backup -n nfs restore latest --target /restore`
  (spec §6); re-`chown` before moving into `volumes/`.
