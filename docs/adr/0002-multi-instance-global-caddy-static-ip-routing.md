# Multi-instance Global Caddy with static-IP routing

There are multiple Global Caddy instances (one on several nodes), and DNS publishes all their
IPs as round-robin A records for crude load balancing. Each app runs in its own `docker compose`
stack on a dedicated Proxmox VM with a reserved static IP; the Global Caddy routes to apps by
`VM-static-IP:sidecar-port` over the wired LAN / Proxmox VLAN.

Routing config is **static and hand-maintained**, not discovered: dynamic mechanisms
(caddy-docker-proxy, Docker labels) can't work because each Global Caddy is on a different VM and
cannot see another VM's Docker daemon. Each app contributes a `global-caddy/sites/<app>.caddy`
snippet, aggregated via `import sites/*.caddy`; all Global Caddy VMs stay identical by
sparse-cloning the `global-caddy/` directory from this repo.

Rejected: Docker Swarm / overlay networking (over-engineered for a home lab; fights the
"each app is a simple standalone compose stack" goal).
