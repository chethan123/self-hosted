---
name: onboard-app
description: Interview-and-scaffold a new app into the self-hosted monorepo, or migrate an existing ad-hoc docker-compose stack into the standard structure. Use when adding or importing an application here.
disable-model-invocation: true
argument-hint: "[new|migrate] [path-to-existing-stack]"
---

# Onboard an app

Bring an application into this monorepo following the standard defined in `CLAUDE.md`,
`CONTEXT.md`, and `docs/adr/`. Read those first — they are the source of truth; this skill
only orchestrates.

## Step 0 — Determine mode

If the user did not pass a mode explicitly, **ask**: "Onboarding mode — `new` (scaffold from
scratch) or `migrate` (import an existing stack)?" Do not assume.

- `migrate` also needs a **local directory path** to the existing stack. Ask for it if absent.

## Interview discipline

Ask questions **one at a time**, each with your recommended answer, and wait. Look up facts
(from `apps/_template/`, existing packages, or the provided stack) instead of asking. Decisions
are the user's. Do not run anything until the package is scaffolded and confirmed.

## Mode: new

1. **Collect the contract** (one question at a time), then write `app.meta.yaml`:
   - `name` (slug), `hostname` (subdomain only), `vm_ip` (reserved static IP), `sidecar_port` (default 80)
   - services and their images; for each: `image_type` (vanilla | self-built | linuxserver)
   - `needs_egress` (default false), `secrets_mode` (default hybrid), whether there is a database
   - any NFS volumes: server IP, export path, container mount path, `access` (ro default | rw)
2. **Scaffold** `apps/<name>/` by copying `apps/_template/` and filling it in:
   - **Names.** Rename the template's `example-app` service to the app slug — never leave it `app`;
     it is the DNS name the sidecar's `reverse_proxy` targets. Give every service an explicit
     `container_name:`: `caddy-<name>` for the sidecar (never plain `caddy` — that is the Global
     Caddy's name), the service name verbatim for everything else. Keep `app.meta.yaml`'s
     `services:` keys equal to the compose service names.
   - Set images, `user:` vs PUID/PGID per `image_type`, the sidecar `reverse_proxy` target port.
   - Remove the `db` service (and its network/secret) if the app has none.
   - Add the app service to the `edge` network **only if** `needs_egress: true`.
   - Write `.env.example` exhaustively; put high-value secrets as `./secrets/*.txt` file-secrets.
   - Write `README.md` from the template.
3. **Write the global route** as a host-matcher **fragment** (NOT a standalone site block) at
   `global-caddy/sites/<name>.caddy`. It is imported *inside* the shared `*.{$BASE_DOMAIN}` block so
   every app reuses the single wildcard cert (ADR-0005). Do **not** wrap it in
   `<host>.{$BASE_DOMAIN} { … }` and do **not** re-`import tls_wildcard`/`security_headers` — those
   are inherited from the enclosing block, and a standalone block would trigger a separate per-host
   cert (the exact thing ADR-0005 avoids):
   ```caddy
   @<name> host <hostname>.{$BASE_DOMAIN}
   handle @<name> {
       reverse_proxy <vm_ip>:<sidecar_port>
   }
   ```
   A two-label hostname (`x.y.{$BASE_DOMAIN}`) is NOT covered by the single-label wildcard — add a
   dedicated `*.y.{$BASE_DOMAIN}` block in `global-caddy/Caddyfile` instead (see the `*.blr` example).
4. **Hand off to hardening**: invoke the `harden-container` skill to run the bring-up loop and
   record `caps_added` / `tmpfs_paths` back into `app.meta.yaml`.
5. **Close out** — remind the user to: create real `.env` + `secrets/*.txt` on the VM (never commit
   them), run `git` from a trusted host (gitleaks pre-commit is active), and `caddy reload` on each
   Global Caddy VM after the route is pulled.

## Mode: migrate

1. **Read** the existing `docker-compose.yml` + `.env` at the given path. Do NOT copy any real
   secret values into committed files.
2. **Map to the standard**, producing `apps/<name>/`:
   - Rename any generic `app` service to the app slug, and add an explicit `container_name:` to
     every service (`caddy-<name>` for the sidecar, the service name verbatim otherwise). Renaming
     a service changes its Docker DNS name — update the sidecar `Caddyfile` and any inter-service
     env var (`POSTGRES_IP=`, etc.) in the same pass. Adding `container_name:` alone changes no DNS.
   - Split networks into `edge` / `frontend` / `backend`; move databases to `backend` only.
   - Replace any host `ports:` on app/db with the sidecar; keep only the sidecar's published port.
   - Convert inline `environment:` secrets to `.env` keys (real values -> the user's gitignored
     `.env`; dummy placeholders -> `.env.example`) and high-value ones to file-secrets.
   - Add the hardening baseline (cap_drop, no-new-privileges, non-root, limits, read_only).
   - Preserve any NFS volumes; record them under `nfs_volumes` and set the mount to `:ro` unless the
     original clearly wrote to them (then `:rw`) — confirm each `access` with the user.
   - Generate the sidecar `Caddyfile` and the `global-caddy/sites/<name>.caddy` route **fragment**
     (host-matcher form, per `new` step 3 — never a standalone block).
3. **Emit a change report** — a clear list of: what was moved/renamed, what still needs a human
   decision (which caps, which services need egress, which secrets to promote to file-secrets),
   and anything in the original that looked unsafe (published ports, docker socket, `privileged`).
4. **Hand off** to `harden-container`, then **close out** as in `new`.

## Invariants to enforce (flag violations)

- No app/db service publishes a host `ports:` — only the sidecar does.
- No service is named `app`; every service sets `container_name:` (`caddy-<name>` for the sidecar).
- No real secret value in any committed file; `.env`, `secrets/`, `volumes/` stay gitignored.
- Every key in `.env` has a placeholder in `.env.example`.
- `read_only: true` unless the app's README documents why it was disabled.
- Every `nfs_volumes` entry has a matching top-level `volumes:` definition and a container mount
  whose `:ro`/`:rw` suffix matches its `access` (default `:ro`). NFS options stay `soft`.
