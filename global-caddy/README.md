# global-caddy

The public front door. Runs as multiple instances (round-robin DNS); every instance stays
identical by sparse-cloning this directory. Terminates TLS with DNS-01 (Cloudflare) and routes each
subdomain to an app's Sidecar Caddy by static IP.

## Deploy to a Caddy VM
```bash
git clone --filter=blob:none --sparse <repo> && cd <repo>
git sparse-checkout set global-caddy
cd global-caddy
cp .env.example .env                          # fill in BASE_DOMAIN, ACME_EMAIL
echo -n '<cloudflare-dns-api-token>' > secrets/dns_token.txt   # gitignored; never commit
docker compose up -d                          # builds the cloudflare-DNS image on first run
```
`secrets/dns_token.txt` and `.env` are gitignored (`**/secrets/*` + `.env`). Create them **on the
VM only**. A Cloudflare token scoped to `Zone:DNS:Edit` for your zone is enough for DNS-01.

## Routes & TLS strategy
**One wildcard cert per zone**, not one per subdomain. The `Caddyfile` has a single
`*.{$BASE_DOMAIN}` block that obtains the wildcard cert (`tls_wildcard`) and applies shared
`security_headers`; every single-label subdomain is a **host-matcher fragment** in
`sites/<name>.caddy`, imported inside that block:
```caddy
# sites/photos.caddy
@photos host photos.{$BASE_DOMAIN}
handle @photos {
	reverse_proxy 10.1.1.4:80
}
```
Fragments carry **only** routing — TLS and headers are inherited from the enclosing block, so they
must **not** redefine them or wrap themselves in a `host { … }` block (that would trigger a separate
per-host cert).

Two-label zones aren't covered by a single-label wildcard, so they get their own blocks directly in
the `Caddyfile`: `*.blr.{$BASE_DOMAIN}` (qbit.blr, tv.blr) and `*.drive.{$BASE_DOMAIN}`. Net result:
**3 wildcard certs** total.

`/onboard-app` appends a fragment here per app. After committing + pulling on each Caddy VM:
```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## Custom image (DNS-01)
Wildcard/subdomain certs need the DNS-01 challenge, which needs the Cloudflare module compiled into
Caddy — stock `caddy:2` lacks it. `Dockerfile` builds it with `xcaddy` (`caddy:2.10` +
`caddy-dns/cloudflare`), tagged `caddy-cloudflare:2.10`. See ADR-0005 for the future plan of baking
config into a versioned image in a local registry.

## Hardening
`read_only`, `cap_drop: [ALL]` + `NET_BIND_SERVICE`, `no-new-privileges`, `mem_limit`/`pids_limit`,
`tmpfs: /tmp`. Certs/ACME state persist in the gitignored `volumes/data` + `volumes/config` binds —
**back these up** (losing them forces re-issuance and can hit Let's Encrypt rate limits).
