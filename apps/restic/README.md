# restic

A self-hosted [rest-server](https://github.com/restic/rest-server) acting as a unified backup
destination — the BorgBase role, for restic. One server, many storage targets, each addressed by
URL path.

- **URL:** https://restic.\<your-domain\>
- **VM / static IP:** restic / 10.1.1.200
- **Upstream:** <https://github.com/restic/rest-server> · image `restic/rest-server:0.14.0`

## How the path routing works

rest-server derives the repository from the request path (`splitURLPath`, `MaxFolderDepth = 2`),
so a single instance rooted at `/data` serves every target with no per-target container and no
rewriting in the Sidecar Caddy:

| URL | container path | host path | backing store |
|---|---|---|---|
| `/local/<machine>/` | `/data/local/<machine>` | `/srv/restic/local` | VM's local SSD |
| `/rclone-1/<machine>/` | `/data/rclone-1/<machine>` | `/srv/restic/rclone-1` | pcloud, via host `rclone mount` |

Two flags define the security posture, both hardcoded in `docker-compose.yml` (not `.env`, so
they can't be lost by editing an untracked file):

- `--append-only` — clients create backups but can never delete or modify them. `forget` and
  `prune` are refused over HTTP; run them on the VM against the directory instead (below).
- `--private-repos` — the Basic-auth username must equal the first path segment. **The htpasswd
  user *is* the storage target.** A leaked `local` credential cannot touch `rclone-1`, and it
  cannot create a stray repo at some other path.

Depth-2 routing means each machine still gets an isolated repo directory under a target while
sharing that target's one credential.

### Adding a target

Three steps, no re-architecting: create + `chown 1000:1000` the host directory, add an htpasswd
user of the same name, add a bind mount to `docker-compose.yml`. Record it under
`storage_targets` in `app.meta.yaml`.

## Deploy

### 1. Host preparation (as root on the restic VM)

```bash
# Target dirs, owned by the container's uid:gid.
mkdir -p /srv/restic/local /srv/restic/rclone-1
chown -R 1000:1000 /srv/restic

# Shared mount so an rclone remount propagates into the container.
# Persist via systemd-tmpfiles or a mount unit — plain `mount` won't survive reboot.
mount --bind /srv/restic /srv/restic
mount --make-rshared /srv/restic
```

### 2. The rclone mount (host, not a container)

FUSE stays on the host so the container needs no `/dev/fuse`, no `CAP_SYS_ADMIN` and no
`apparmor:unconfined`. Sketch of `/etc/systemd/system/srv-restic-rclone\x2d1.mount`'s companion
service — adjust the remote name to your rclone config:

```ini
[Unit]
Description=rclone mount: pcloud -> /srv/restic/rclone-1
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount pcloud:restic /srv/restic/rclone-1 \
    --config /root/.config/rclone/rclone.conf \
    --vfs-cache-mode writes \
    --vfs-cache-max-age 24h \
    --uid 1000 --gid 1000 \
    --allow-other \
    --dir-cache-time 1m
ExecStop=/bin/fusermount -uz /srv/restic/rclone-1
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

- `--allow-other` requires `user_allow_other` in `/etc/fuse.conf` — without it the Docker daemon
  (root) cannot traverse a mount owned by uid 1000.
- `--vfs-cache-mode writes` is the **minimum**; restic needs write-then-rename semantics that a
  cache-less mount does not provide.
- Order the Docker unit after this one so the container never starts against an unmounted path.

### 3. The stack

```bash
cp .env.example .env

# One bcrypt line per target; username MUST equal the path segment.
docker run --rm --entrypoint htpasswd restic/rest-server:0.14.0 \
    -nbB local    'STRONG-PASSWORD-1' >  secrets/htpasswd
docker run --rm --entrypoint htpasswd restic/rest-server:0.14.0 \
    -nbB rclone-1 'STRONG-PASSWORD-2' >> secrets/htpasswd
chown 1000:1000 secrets/htpasswd && chmod 640 secrets/htpasswd

docker compose up -d
```

`create_user` from the image's docs does **not** apply here: the htpasswd file is a read-only
file-secret and the container is non-root. Generate it on the host, as above.

## Client usage

```bash
export RESTIC_REPOSITORY='rest:https://local:STRONG-PASSWORD-1@restic.<your-domain>/local/laptop/'
export RESTIC_PASSWORD='<repo-encryption-password>'   # separate from the HTTP password

restic init
restic backup ~/Documents
restic snapshots
```

The same machine backing up to the cloud target uses the *other* credential:

```bash
restic -r 'rest:https://rclone-1:STRONG-PASSWORD-2@restic.<your-domain>/rclone-1/laptop/' backup ~/Documents
```

## Retention / pruning

`--append-only` refuses `forget` and `prune` over HTTP by design. rest-server uses restic's local
backend layout byte-for-byte, so maintenance runs on the VM against the directory:

```bash
restic -r /srv/restic/local/laptop forget --keep-daily 7 --keep-weekly 4 --prune
```

Run it as uid 1000 so file ownership stays consistent.

## Notes

- **Egress:** none. `app` sits only on the internal `frontend` network; the host's rclone unit is
  what reaches pcloud.
- **Hardening deviations:** none requested. `read_only: true`, `cap_drop: [ALL]` with nothing
  added, non-root via `user: "1000:1000"`. The reasoning is that rest-server writes only into the
  bind-mounted target directories, and the htpasswd file is pre-created so the entrypoint's
  `touch` branch never fires — but **this has not been verified on a running container.** The VM
  did not exist at onboarding time, so the `/harden-container` bring-up loop has not run yet
  (`hardening_verified: false` in `app.meta.yaml`). Run `/harden-container apps/restic` on first
  deploy and record whatever the loop actually finds.
- **The failure mode to watch:** if the rclone mount is down when a backup runs, writes land on
  the local SSD underneath the mountpoint and the backup *appears* to succeed. `rshared`
  propagation plus systemd ordering are the defence; verify periodically with
  `findmnt /srv/restic/rclone-1`.
- **Backups of this VM:** `volumes/` holds only the Sidecar Caddy's state. The real payload is
  `/srv/restic/*`, which is outside the app package — snapshot it separately.
