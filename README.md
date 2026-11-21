# self-hosted

Self-hosted apps, each a Docker Compose stack on its own Proxmox VM. **Being rebuilt.**

The previous design is on branch `backup-2026-11-20`: five app packages, the Global Caddy, a backup
sidecar image, ADRs, specs and agent skills. None of it was ever deployed from this repo.
[`BASELINE.md`](BASELINE.md) records what existed, its state, and a proposed baseline for each part,
with the questions still to decide. Start there.

```bash
git show backup-2026-11-20:<path>              # read an old file
git checkout backup-2026-11-20 -- <path>       # bring one back
```

**A VM that checked out `global-caddy/` or an `apps/` directory from `main` must not `git pull`.**
Those files are gone from `main`, so a pull deletes the config under a running container. Pin it to
the snapshot first: `git checkout backup-2026-11-20`.

To decide the baseline with an agent: *"Read BASELINE.md and walk me through the open items."*

Kept on `main`: `.gitignore` (keeps `.env`, `secrets/*` and `volumes/` out of git) and the gitleaks
pre-commit hook. Enable it once per clone:

```bash
pip install pre-commit && pre-commit install
```
