# restic-server

A backup gateway that speaks restic's REST protocol to clients and writes to three independent
storage targets, each addressed by URL path under one hostname. Full design:
`docs/specs/restic-server.md` — read it before changing anything here; every decision in its §7
was made deliberately.

- **URL:** `https://backup.<your-domain>`
- **VM / static IP:** restic-server / `10.1.1.100`
- **Sidecar port:** `443` (TLS, not the fleet's usual `80` — see below)
- **Replaces:** `restic.<your-domain>` / `10.1.1.200` (the superseded `apps/restic/` package).
  `backrest.<your-domain>` / `10.1.1.250` is a separate, untouched app.

## Paths

One hostname, three targets, demultiplexed by path (`handle_path`, not a host matcher — a
deliberate deviation from ADR-0002; see spec §8 "Routing"):

| Path | Upstream | Backing store |
|---|---|---|
| `/nfs/<app-slug>/` | `rest-server:8000` | NFS export `192.168.86.250:/export/restic` |
| `/rsync-net/<app-slug>/` | `rclone-rsync-net:8080` | rsync.net, over SFTP |
| `/pcloud/<app-slug>/` | `rclone-pcloud:8080` | pcloud, region US (`api.pcloud.com`) |

Every target is append-only and `--private-repos`: the Basic-auth username must equal
`<app-slug>`, so a leaked credential for one app cannot touch another app's repository on any
target. `restic forget`/`prune`/`key remove` are refused (403) on all three — that's the
maintenance path's job (§9 of the spec, not built yet).

## Why three servers, not one

The NFS target is a real filesystem, so `restic/rest-server` runs on it directly. The two cloud
targets are APIs, so `rclone serve restic` speaks restic's protocol on one side and the
provider's API on the other, with no filesystem and no cache in between — restic's own
documented recommendation for backends that lack native append-only. See spec §5, §7 (D1) for
why the rclone Docker volume plugin was rejected instead.

## Networks

| network | members | purpose |
|---|---|---|
| `edge` | caddy, rclone-rsync-net, rclone-pcloud | published port; egress for the two cloud targets |
| `frontend` | caddy, rest-server, rclone-rsync-net, rclone-pcloud | sidecar ⇄ all three backends, no internet |

**No `backend` network** — this app has no database. All three backends share `frontend`; under
D7 (backends own authentication) that's safe, since reaching another service still requires that
service's own credential.

**No slug-named service.** `CLAUDE.md` normally requires the app service to be named after the
app slug. This package has three upstreams instead of one, so none of them is `restic-server` —
`app.meta.yaml`'s `routes:` block (jellyfin-style) names each path and its upstream instead.

## Operator prerequisites (before first start)

This package has no host-*daemon* prerequisites — nothing installed outside `docker compose`,
no FUSE, no capability grants. It is not zero-setup, though. These must exist first:

1. **NFS export.** `192.168.86.250:/export/restic` created and owned `1000:1000`, *without*
   squashing that UID into `nobody` (check `anonuid`/`anongid` on the export).
2. **rsync.net account.** An SSH keypair registered with rsync.net, and its host key captured
   for `known_hosts` — rclone does **no** host-key validation unless `known_hosts_file` is set.
3. **pcloud OAuth grant.** Run `rclone authorize "pcloud"` on any machine with a browser; the
   resulting token has a zero expiry (never needs refreshing — see D9), so it's a one-time step.
4. **Three htpasswd files.** One bcrypt line per onboarded app, per target — see "Building the
   secrets" below.
5. **Global-Caddy route fragment.** `global-caddy/sites/backup.caddy` (already added by this
   change) installed on every Caddy VM via its sparse checkout, then `caddy reload`.
6. **Sidecar CA bootstrap.** `tls internal` generates its own root the first time Caddy starts.
   Do this once, before the Global-Caddy fragment is useful:
   ```bash
   docker compose up -d caddy
   cp volumes/caddy/pki/authorities/local/root.crt /path/to/self-hosted/global-caddy/backup-ca.crt
   # commit global-caddy/backup-ca.crt, then on every Global Caddy VM:
   caddy reload
   ```
   Repeat this whenever `volumes/caddy` is lost — the CA regenerates and the old root stops
   matching, so the Global Caddy returns 502 for `backup.<domain>` until the new root is
   re-committed and reloaded.
7. **Retire the old route.** Once this package is live, delete
   `global-caddy/sites/restic.caddy` and decommission `10.1.1.200` on every Caddy VM. **Not done
   by this change** — it's a manual cutover step for whoever deploys this, and Backrest
   (`10.1.1.250`) should be checked for whether it still points at `10.1.1.200` first (see Notes).

## Building the secrets

None of these are committed — only `secrets/.gitkeep` is. Generate all of them before
`docker compose up`.

```bash
cp .env.example .env   # fill in BASE_DOMAIN and RSYNC_NET_REMOTE_PATH for real

# --- htpasswd, one file per target, one bcrypt line per app slug ---
# Placeholder slug used below: `example-app`. Real onboarding: append one more line per file,
# per app, then restart the affected backend (see "Onboarding a new app").
docker run --rm --entrypoint htpasswd restic/rest-server:0.14.0 \
    -nbB example-app 'STRONG-PASSWORD-1' > secrets/htpasswd-nfs
docker run --rm --entrypoint htpasswd restic/rest-server:0.14.0 \
    -nbB example-app 'STRONG-PASSWORD-2' > secrets/htpasswd-rsync-net
docker run --rm --entrypoint htpasswd restic/rest-server:0.14.0 \
    -nbB example-app 'STRONG-PASSWORD-3' > secrets/htpasswd-pcloud
chown 1000:1000 secrets/htpasswd-* && chmod 640 secrets/htpasswd-*

# --- rsync.net: SSH key + pinned host key (PLACEHOLDERS — replace with your real account) ---
cp /path/to/your/rsync-net-key secrets/rsync-net.key
chmod 600 secrets/rsync-net.key
# One line, exactly as published by rsync.net / captured with ssh-keyscan:
echo 'CHANGEME.rsync.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAACHANGEMECHANGEMECHANGEME' \
    > secrets/rsync-net.known_hosts

# --- rclone remote configs (PLACEHOLDERS in the rsync-net stanza — replace host/user/path) ---
cat > secrets/rclone-rsync-net.conf <<'EOF'
[rsync-net]
type = sftp
host = CHANGEME.rsync.net
user = CHANGEME1234
key_file = /run/secrets/rsync-net.key
known_hosts_file = /run/secrets/rsync-net.known_hosts
shell_type = unix
EOF

cat > secrets/rclone-pcloud.conf <<'EOF'
[pcloud]
type = pcloud
hostname = api.pcloud.com
token = {"access_token":"...","token_type":"bearer","expiry":"0001-01-01T00:00:00Z"}
EOF
# ^ `token` comes from `rclone authorize "pcloud"` (step 3 above) — paste its output verbatim.

chown 1000:1000 secrets/rclone-*.conf secrets/rsync-net.* && chmod 640 secrets/rclone-*.conf secrets/rsync-net.*

docker compose up -d
```

**Note the trailing bind-mount caveat:** both servers reload htpasswd on the mounted file's
inode mtime, but editing it in place (most editors, `htpasswd(1)`) writes temp-then-rename —
invisible behind a single-file bind mount until the container restarts. Plan on a restart when
adding an app (below), not a live reload.

## Onboarding a new app

Three steps, no compose changes:

1. Append one bcrypt line per target to the three htpasswd files, username = the new app's slug
   (same command as above, `>>` instead of `>`).
2. Restart the three backend containers so each picks up its htpasswd file
   (`docker compose restart rest-server rclone-rsync-net rclone-pcloud`) — see the bind-mount
   caveat above.
3. Hand the app team their three credentials (below).

## Client usage

```bash
# https://, not http:// — the Global Caddy's plain-HTTP listener redirects, and restic's REST
# backend does not carry Basic-auth userinfo through a redirect: a http:// repo URL 401s on the
# very first call, after the credential has already crossed the LAN in cleartext.
export RESTIC_REPOSITORY="rest:https://backup.<your-domain>/nfs/example-app/"
export RESTIC_REST_USERNAME=example-app
export RESTIC_REST_PASSWORD_FILE=/run/secrets/rest_password   # or RESTIC_REST_PASSWORD
export RESTIC_PASSWORD_FILE=/run/secrets/restic_password      # repo encryption key — separate
restic init
restic backup /data --tag nightly
restic snapshots
restic restore latest --target /restore
```

Repeat against `/rsync-net/example-app/` and `/pcloud/example-app/` with that target's
credential — three separate uploads, no cross-target deduplication, by design (D2).
`restic forget`/`prune`/`key remove` fail with 403; `restic unlock` works (both servers exempt
`locks/` from the delete ban).

**Client-side backup jobs (what actually runs `restic backup` on each app VM) are not part of
this package** — deferred, along with `apps/_template/` and `/onboard-app` changes (spec §12).

## Notes

- **Hardening is NOT verified.** `/harden-container` has never run against this package
  (`hardening_verified: false`) — out of scope for this change, same as the superseded
  `apps/restic`. `caps_added: []` and the `tmpfs_paths` above are the optimistic starting
  posture, not a measured minimum.
- **rsync.net's ZFS snapshot immutability — UNVERIFIED.** It's the only backstop that survives
  compromise of this VM; the authoring environment couldn't reach rsync.net to confirm it.
  Verify before relying on it (spec §11).
- **bcrypt-per-request on `rclone serve restic` — UNMEASURED.** `rest-server` caches verified
  passwords for 60s; rclone's htpasswd path has no such cache, and a backup is thousands of
  Basic-authenticated requests. Measure at bring-up. If it's prohibitive, spec §8 has an ordered
  fallback ladder (`{SHA}` htpasswd entries, then Caddy-side header auth with per-service
  networks) — don't reach for `--user`/`--pass`, which can't express per-app identity.
- **htpasswd files are hand-maintained across three services — accepted for now.** Rots quickly
  once more than a couple of apps are onboarded; a follow-on should derive them from
  `app.meta.yaml` (spec §11, §12).
- **Backrest (`10.1.1.250`) may still target the retired `10.1.1.200`.** Repointing it is
  deferred client-side work, not part of this change.
- **Availability isolation is not achieved.** Append-only permits unlimited *additions*; one
  compromised app can exhaust the NFS export or either cloud target's quota and stop every other
  app's backups. Confidentiality and integrity are covered (spec §10); availability is not.
- **No monitoring or freshness alerting.** A backup system that stops silently is worse than
  none — the largest known gap, deferred with the client-side work (spec §11).
- **Verify at bring-up:** one `curl -v` confirming `handle_path` preserves the trailing slash
  (`/nfs/example-app/` → `/example-app/`); the client examples above assume it does.
- **The maintenance path (`forget`/`prune`/`check`) is designed, not built.** It runs from a
  separate, normally-powered-off VM (spec §9) — `apps/restic-maintenance/` is future work.
- **Backups of this VM:** `volumes/` holds only the sidecar's Caddy state (including its CA — see
  the bootstrap step above). The actual repositories live on the NFS export and the two cloud
  targets, outside this VM.
