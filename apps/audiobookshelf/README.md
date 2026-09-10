# audiobookshelf

Self-hosted audiobook and podcast server. One app, one subdomain, one published port.

- **URL:** `https://audiobooks.<domain>`
- **VM / static IP:** audiobookshelf / 10.1.1.3
- **Published port:** `:80` only (the Sidecar Caddy)
- **Upstream:** <https://www.audiobookshelf.org> · `ghcr.io/advplyr/audiobookshelf`

## Networks

| network | members | purpose |
|---|---|---|
| `edge` | caddy, audiobookshelf | published port; egress |
| `frontend` | caddy, audiobookshelf | sidecar ⇄ app, no internet |

No `backend` network: there is no database service. Audiobookshelf keeps its SQLite database
inside `/config`.

`needs_egress: true` — the app fetches book and podcast metadata from the internet and downloads
podcast episodes. Without `edge` it starts fine and then quietly fails every lookup.

## Storage

| export / path | container path | access |
|---|---|---|
| `192.168.86.250:/export/audiobooks` | `/audiobooks` | **rw** |
| `192.168.86.250:/export/podcasts` | `/podcasts` | **rw** |
| `./volumes/audiobookshelf/config` | `/config` | local — SQLite DB |
| `./volumes/audiobookshelf/metadata` | `/metadata` | local — covers, streams, backups, logs |

`/config` **must stay local**. It holds the SQLite database, and SQLite over NFS corrupts — this
is called out in the upstream docs and is the one storage decision here that is not a preference.

Both NFS libraries are `:rw`. Podcasts has no alternative (episode downloads land there).
Audiobooks is `rw` because Audiobookshelf's write-back features — embedding metadata into audio
files, the m4b merge tool, web-UI uploads, and file renaming — all modify the library folder in
place. If you stop using those, tightening `/audiobooks` to `:ro` is a one-word change here and
in `app.meta.yaml`. NFS options stay `soft`; `hard` has caused hangs here.

## Deploy

```bash
cp .env.example .env                     # fill in real values; NFS_SERVER is mandatory

# Directories must exist, owned by 975:975, before first start — cap_drop: [ALL] means no
# CAP_DAC_OVERRIDE, so a root-owned directory is simply unwritable to the container.
mkdir -p volumes/audiobookshelf/config volumes/audiobookshelf/metadata volumes/caddy
sudo chown -R 975:975 volumes/audiobookshelf

docker compose up -d
```

Then `caddy reload` on each Global Caddy VM once `global-caddy/sites/` is pulled. The route
fragment (`global-caddy/sites/audiobooks.caddy` → `10.1.1.3:80`) already exists and is unchanged
by this migration.

There is no `secrets/*.txt` step: this stack has no file-secrets. The admin account is created
through the web UI on first visit and lives in the database under `volumes/`.

## Notes

- **Hardening is NOT verified.** `/harden-container` has never run against this package
  (`hardening_verified: false`). The source stack ran with **no** `cap_drop`, **no** `read_only`
  and the full default capability set, so every hardening line here is new and untested.
  `read_only: true` on `audiobookshelf` is the most likely first-boot failure — watch for
  `EROFS` on paths outside `/config`, `/metadata` and `/tmp`, and add tmpfs mounts for what it
  actually needs rather than flipping `read_only` off.
- **Port 80 inside the container, as a non-root user.** Audiobookshelf's image default is `:80`
  and the source stack ran it that way, so it is unchanged. It works because Docker sets
  `net.ipv4.ip_unprivileged_port_start=0` inside containers by default — no capability is
  involved, and `cap_drop: [ALL]` does not affect it. If a host ever overrides that sysctl the
  app will fail to bind; the fix is to set `PORT=13378` in the environment and point the sidecar
  at `audiobookshelf:13378`, **not** to hand back `CAP_NET_BIND_SERVICE`.
- **The `init.sh` / `start.sh` / `stop.sh` / `session.sh` scripts are gone.** `init.sh` chose
  local-vs-NFS interactively at runtime, which is exactly the state that belongs in a committed
  file — the volumes are now declared in `docker-compose.yml`. The other three wrapped
  `docker compose up -d` / `down`.
- **Backups:** `volumes/audiobookshelf/config` is the one that matters — it holds the library
  database, users, and all listening progress. `metadata` is regenerable cache (though it also
  holds Audiobookshelf's own scheduled backups). The audio itself lives on the NAS exports and
  is backed up there, not from this VM.
