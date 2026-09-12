# Self-Hosted Monorepo

The single source of truth for every self-hosted application, one directory per app,
each a standalone `docker compose` stack deployed to its own Proxmox VM. This file is a
glossary only — it defines the project's vocabulary, not how anything is implemented.

## Language

**App package**:
A self-contained directory under `apps/` holding one application's `docker-compose.yml`,
edge config, env template, and metadata. The unit of deployment.
_Avoid_: stack, project, service (a service is one container *within* a package)

**Global Caddy**:
The public-facing reverse proxy. Terminates TLS (wildcard cert), routes each subdomain to
the correct app's Sidecar Caddy by static IP. Runs as multiple instances behind round-robin DNS.
_Avoid_: edge proxy, load balancer, ingress

**Sidecar Caddy**:
A per-app reverse proxy that fronts the application container. Owns app-specific edge
concerns (headers, auth, rate limits, path rules) and is the only LAN-exposed port on the VM.
_Avoid_: local proxy, app proxy

**Global-route snippet**:
A per-app file in `global-caddy/sites/<app>.caddy` declaring `subdomain -> VM-IP:port`.
Aggregated by the Global Caddy via `import`.
_Avoid_: route config, vhost

**edge / frontend / backend**:
The three per-VM Docker networks. `edge` is a bridge (sidecar's published port + optional
egress); `frontend` is internal-only (Sidecar Caddy ⇄ app); `backend` is internal-only (app ⇄ db).
_Avoid_: public/private net, dmz

**needs_egress**:
A per-app flag. When true, the app container is added to an egress-capable network; when false
(the default) the app has no internet access.
_Avoid_: internet-enabled, online

**app.meta.yaml**:
The machine-readable contract for an app package: hostname, VM IP, port, image type, egress,
and the hardening decisions (caps added, tmpfs paths). Drives linting and documentation.
_Avoid_: manifest, config, descriptor

**Onboard**:
Adding an app to the monorepo, either `new` (scaffold from scratch) or `migrate` (import an
existing ad-hoc stack). Performed by the `/onboard-app` skill.
_Avoid:_ add, import, provision

**Hardening bring-up loop**:
The iterative process of starting a maximally-locked-down container, observing what breaks
(`EPERM` for a missing capability, `EROFS` for a read-only path), and adding back the minimum
capability or tmpfs mount. Performed by the `/harden-container` skill.
_Avoid_: security pass, lockdown

**Backup sidecar**:
The `backup` service in a package's `docker-compose.backup.yml`: the house image
(`images/backup-sidecar/`, resticprofile + supercronic) pushing the backup set to every
restic-server target on the app's schedule, as the account that owns the set.
_Avoid_: backup agent, restic container, backup job

**Backup set**:
What a package backs up — exactly the read-only binds under `/backup/<name>` in its
`docker-compose.backup.yml`, mirrored in `app.meta.yaml`'s `backup.sources`. Nothing else is
visible to the sidecar, so nothing else can be backed up.
_Avoid_: backup paths, include list, sources (alone)

**Dump service**:
A per-database service in the database engine's own image that writes a verified dump into
`volumes/dumps` on its own schedule, so the backup set holds dumps and never a live datadir.
_Avoid_: db backup, exporter

**File-secret**:
A high-value secret mounted as a file at `/run/secrets/<name>` and read via the `*_FILE`
convention, rather than injected as an environment variable.
_Avoid_: docker secret, mounted secret
