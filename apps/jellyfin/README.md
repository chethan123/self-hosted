# jellyfin

The media VM: Jellyfin behind a ProtonVPN tunnel, plus metube, a WebDAV share, and Jellystat.
One package, four subdomains, one published port.

- **URLs:** `https://tv.<domain>` · `https://metube.<domain>` · `https://jellyshare.<domain>` ·
  `https://jellystats.<domain>`
- **VM / static IP:** jellyfin / 10.1.1.2
- **Published port:** `:80` only (the Sidecar Caddy)

## Why these six services share a package

They are coupled by storage, not convenience. metube writes into the same `youtube` export
Jellyfin reads; rclone-webdav serves the same `jelly-share` export Jellyfin reads. Splitting them
across VMs would mean mounting each NFS export from two places.

## The VPN namespace

`jellyfin` has **no network of its own**. It runs inside gluetun's namespace
(`network_mode: service:gluetun`), so all its outbound traffic — metadata lookups, artwork
fetches — leaves through ProtonVPN. The consequence you will trip over:

> **Everything addresses Jellyfin as `gluetun:8096`, never `jellyfin:8096`.**

That is why the Sidecar Caddy and Jellystat both sit on `frontend` alongside gluetun — gluetun's
firewall accepts inbound traffic from the subnets it is attached to. When you point Jellystat at
its server in the UI, the URL is `http://gluetun:8096`.

metube is **not** behind the VPN; it kept the direct egress it had in the source stack.

## Networks

| network | members | purpose |
|---|---|---|
| `edge` | caddy, gluetun, metube, rclone-webdav | published port; egress |
| `frontend` | caddy, gluetun, metube, rclone-webdav, jellystat | sidecar ⇄ services, no internet |
| `backend` | jellystat, jellystat-db | app ⇄ db, no internet; sidecar cannot reach the db |

`rclone-webdav` is on `edge` for one reason: it runs `apk add rclone` on every start and needs
the Alpine mirrors just to boot.

## Routing

All four subdomains resolve to `10.1.1.2:80`. The Sidecar Caddy demultiplexes them by `Host`
header, which is why `BASE_DOMAIN` must be set in `.env` — with it unset every matcher silently
misses and you get the sidecar's `Service not found` 404. That is the first thing to check when a
subdomain breaks.

| subdomain | sidecar upstream |
|---|---|
| `tv` | `gluetun:8096` (Jellyfin) |
| `metube` | `metube:8081` |
| `jellyshare` | `rclone-webdav:8080` |
| `jellystats` | `jellystat:3000` |

## Storage

| export | service | container path | access |
|---|---|---|---|
| `/export/jellyfin` | jellyfin | `/media` | **rw** |
| `/export/youtube` | metube | `/downloads` | **rw** |
| `/export/youtube` | jellyfin | `/youtube` | ro |
| `/export/jellyfin-share` | rclone-webdav | `/data` | **rw** |
| `/export/jellyfin-share` | jellyfin | `/shared` | ro |

Jellyfin keeps `rw` on `/media` for delete-from-UI and write-back metadata, but only reads the
other two libraries — so a Jellyfin fault cannot damage metube's downloads or the WebDAV
drop-box. NFS options stay `soft`; `hard` has caused hangs here.

## Deploy

```bash
cp .env.example .env                     # fill in real values — BASE_DOMAIN is mandatory

# Bind-mounted to /run/secrets/wireguard_private_key — already gluetun's default path, no extra wiring.
printf '%s' 'YOUR-WIREGUARD-PRIVATE-KEY' > secrets/wireguard_private_key
# gluetun: root, but cap_drop [ALL] — no CAP_DAC_OVERRIDE, ordinary perm bits apply.
# User-owned 600 is unreadable to it: silent "permission denied", tunnel never comes up.
# root:root + 600 lets it read as owner, no capability granted back.
sudo chown root:root secrets/wireguard_private_key
sudo chmod 600 secrets/wireguard_private_key

docker compose up -d
```

Then `caddy reload` on each Global Caddy VM once `global-caddy/sites/` is pulled.

### Verify the VPN is actually up

```bash
docker compose exec gluetun wget -qO- https://ipinfo.io/ip    # must NOT be your WAN IP
```

## Notes

- **Hardening is NOT verified.** `/harden-container` has never run against this package
  (`hardening_verified: false`). `read_only: true` on `metube`, `jellystat` and `jellystat-db` is
  the standard default applied optimistically — those are the most likely first-boot failures.
  Run the bring-up loop on first deploy and record what it actually finds.
- **Recorded deviations from the hardening baseline:**
  - `gluetun` — `NET_ADMIN` + `/dev/net/tun`, and `read_only: false`. Irreducible for a VPN
    client: it creates a tunnel interface and rewrites iptables state at runtime.
  - `jellyfin` — `read_only: false`; s6-overlay writes across the rootfs during init. Keeps the
    five caps the source stack ran with (`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, `SETUID`),
    which are what s6 needs to chown `/config` and drop to PUID/PGID. `/dev/dri` for VAAPI.
    `cpus` is deliberately unset so transcoding can use every core.
  - `rclone-webdav` — runs as **root** with `read_only: false`, because `apk add` requires both.
    This was a deliberate choice to keep the source behaviour; the alternative is a pinned
    `rclone/rclone` image, which would allow non-root and a read-only rootfs.
- **Unpinned dependency:** the rclone binary. Images are pinned, but `apk add --no-cache rclone`
  resolves to whatever Alpine ships on the day the container restarts, and the container needs
  internet to start at all — a mirror outage means a failed boot.
- **Postgres data path:** the mount is `./volumes/jellystat/db:/var/lib/postgresql`, **not**
  `/var/lib/postgresql/data`. Postgres 18 moved the data directory to `/var/lib/postgresql/18/docker`
  and that is what the existing database was created under. "Fixing" this path to the more familiar
  one presents initdb with an empty directory and it will start a brand-new empty cluster.
- **Backups:** `volumes/` holds Jellyfin's `/config` (all library metadata, users, and watch
  state), Jellystat's Postgres data, and the sidecar's state. The media itself lives on the NAS
  exports and is backed up there, not from this VM.
