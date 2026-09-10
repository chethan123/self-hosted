# Read-only, maximally-hardened container default

Because we run open-source apps whose own hardening we don't fully trust, the default posture is
maximally locked down, loosened per-app only where proven necessary:

- `cap_drop: [ALL]` then add back only capabilities the app proves it needs
- `security_opt: [no-new-privileges:true]`
- non-root: `user: "UID:GID"` for vanilla/self-built images; **PUID/PGID** for linuxserver.io
  images (their init starts as root to fix volume ownership then drops — forcing `user:` breaks them)
- `read_only: true` root filesystem with writable paths exposed as sized `tmpfs` or volumes
- `pids_limit`, `mem_limit`, `cpus` set; pinned image tags (never `:latest`)
- never `privileged`, never mount the Docker socket, keep the default seccomp profile

`read_only: true` is **default-ON** with a per-app off switch. The trade-off is real friction:
`cap_drop:[ALL]` and `read_only` break many apps on first run, so hardening is not a static template
but an iterative **bring-up loop** (see ADR-0004 and the `/harden-container` skill). The minimal caps
and tmpfs paths discovered are recorded in each app's `app.meta.yaml` so they are auditable.
