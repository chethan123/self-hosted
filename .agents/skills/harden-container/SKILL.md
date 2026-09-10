---
name: harden-container
description: Iteratively harden an app's containers - start maximally locked down, observe what breaks, add back the minimum capabilities and tmpfs paths. Use when hardening a new or migrated app, or tightening an existing one. Has direct (Docker local) and assisted (Docker on a remote VM) modes.
argument-hint: "[direct|assisted] [app-name]"
---

# Harden a container (bring-up loop)

Find the **minimum** privileges an app needs, starting from the maximally-hardened default in
ADR-0003. Never add a capability or tmpfs path speculatively — add only what an observed failure
proves is needed, and record every addition in the app's `app.meta.yaml`.

## Step 0 — Determine mode

The authoring host and the Docker host are usually different (ADR-0004). If mode isn't given, ask:
- **direct** — a Docker daemon is reachable *here*; this skill runs the commands.
- **assisted** — Docker is on a remote VM; this skill prints commands for the operator to run and
  reads back the pasted output.

Detect when possible: if `docker info` succeeds here, offer `direct`; otherwise use `assisted`.

## The loop

Repeat until the app runs cleanly with the smallest privilege set:

1. **Start locked down**: `cap_drop:[ALL]`, no `cap_add`, `read_only: true`, `tmpfs: []`,
   `no-new-privileges`, non-root. (direct: `docker compose up`; assisted: tell the operator to run
   it and paste `docker compose logs`.)
2. **Read the failure**:
   - `EROFS` / "read-only file system" -> the app writes to that path. Add it as a sized `tmpfs`
     (e.g. `/tmp:size=64m,mode=1777`) if ephemeral, or a volume if it must persist.
   - `EPERM` / "operation not permitted" -> a missing capability. Identify it:
     `docker run --cap-add=SYS_PTRACE <img> strace -f -e trace=%process,network <entrypoint>`,
     or check what it wants with `getpcaps 1` / `capsh --decode`. Add back **one** capability, re-test.
   - Permission-denied on bind mounts with a linuxserver.io image -> it needs PUID/PGID and the
     ownership caps `CHOWN SETUID SETGID DAC_OVERRIDE FOWNER` (this combo is the #1 self-inflicted
     breakage — see the research in ADR-0003).
3. **Re-test** after each single change. Stop as soon as it's healthy.
4. **If it simply cannot run read-only** after reasonable effort, set `read_only: false`, and write
   *why* into the app's `README.md`. This is the documented escape hatch, not a default.

## Record the result

Write the final minimal set into `app.meta.yaml` (`caps_added`, `tmpfs_paths`, `read_only` per
service) and mirror them as comments in `docker-compose.yml`. The recorded set is the audit trail —
someone must be able to see exactly what was loosened and why.

## Assisted-mode etiquette

Give copy-pasteable commands one block at a time, say what output you need back
(`docker compose logs app`, `docker inspect`, `getpcaps`), and wait. Diagnose from the pasted
output; don't guess ahead of the logs.
