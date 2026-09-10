# Authoring host and Docker host are separate

Claude Code / repo authoring happens on an admin machine that may have no Docker daemon, while
Docker runs on the Proxmox VMs which don't have Claude Code. Scaffolding (writing files) therefore
happens from a full checkout on the admin host; the **hardening bring-up loop** must run where
Docker is.

Consequently the `/harden-container` skill has two modes:

- **direct** — used when a Docker daemon is reachable where the skill runs; it starts the stack and
  iterates automatically.
- **assisted** — used when Docker is elsewhere; the skill prints the exact commands to run on the VM,
  the operator pastes back logs / command output, and the skill diagnoses and updates the config.

Workflow: scaffold on the admin host → commit → sparse-pull on the VM → run the hardening loop
there → record the discovered caps/tmpfs back into `app.meta.yaml` → commit again.
