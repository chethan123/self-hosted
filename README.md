# self-hosted

A private monorepo of self-hosted applications. Each app is a standalone `docker compose` stack in
its own directory, deployed to a dedicated Proxmox VM, fronted by a per-app Caddy sidecar behind a
shared, TLS-terminating Global Caddy.

## Layout

| Path | What |
|---|---|
| `apps/<name>/` | one app package (`apps/_template/` is the canonical shape) |
| `global-caddy/` | the shared public reverse proxy (wildcard TLS, subdomain routing) |
| `docs/adr/` | why the architecture is the way it is (ADR 0001–0005) |
| `CONTEXT.md` | domain glossary |
| `CLAUDE.md` | conventions + golden rules |
| `.claude/skills/` | `/onboard-app`, `/harden-container` |

## First-time setup

```bash
pip install pre-commit && pre-commit install   # enable gitleaks secret scanning
```

## Add an app

In Claude Code, run **`/onboard-app`** — mode `new` to scaffold from scratch, or
`migrate <path-to-existing-stack>` to import an ad-hoc compose stack into the standard. It
interviews you, scaffolds the package, writes the global route, and runs the hardening loop
(`/harden-container`).

## Deploy an app (on its VM)

```bash
git clone --filter=blob:none --sparse <repo> && cd <repo>
git sparse-checkout set apps/<name>
cd apps/<name>
cp .env.example .env                 # fill in real values
# create any secrets/*.txt file-secrets
docker compose up -d
```

## Non-negotiables

- Never commit `.env`, `secrets/*`, or `volumes/` (gitignored; gitleaks guards commits).
- Only Caddy publishes host ports. Apps and DBs stay on internal Docker networks.
- Hardened by default (`read_only`, `cap_drop:[ALL]`, non-root); loosen per-app with a recorded reason.
- The real base domain is never committed — it's `{$BASE_DOMAIN}` from a gitignored `.env`.
