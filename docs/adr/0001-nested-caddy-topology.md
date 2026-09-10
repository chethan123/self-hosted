# Nested Caddy topology (global + per-app sidecar)

Every web app is fronted by its own **Sidecar Caddy** (plain HTTP), which sits behind a
shared **Global Caddy** that terminates TLS: `client --https--> Global Caddy --http--> Sidecar --> app`.
This is deliberately a nested proxy (an uncommon default) chosen for two distinct reasons, which
are separate protections and must not be conflated:

- **Inbound control (the sidecar's job):** an HTTP-aware choke point in front of an app we don't
  fully trust, where per-app auth, headers, rate limits, and path allow-lists can be tightened over
  time. Only the sidecar is exposed on the LAN — never the app's own server.
- **Containment (NOT the sidecar's job):** a breached app is kept off the main network by the
  VM boundary + Docker network segmentation + no published app ports — *not* by the sidecar.

Considered and rejected: a single global proxy straight to each app (loses the per-app tightenable
edge and exposes the app server directly). The cost of this decision is more moving parts (N sidecars,
N Caddyfiles), accepted for the isolation and per-app-config-co-location it buys.
