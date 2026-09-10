# Wildcard cert via DNS-01, subdomain-per-app routing

Each Global Caddy obtains a single wildcard certificate for `*.{$BASE_DOMAIN}` and routes each app
by subdomain (`photos.` -> immich, `drive.` -> seafile, ...). One wildcard cert covers every app
regardless of count, which sidesteps Let's Encrypt duplicate-certificate rate limits that would
otherwise bite with multiple Global Caddy instances each issuing per-hostname certs.

A wildcard cert **requires the DNS-01 challenge** (HTTP-01 cannot issue wildcards). This carries one
dependency: the Global Caddy image must be built with the DNS provider's module (stock `caddy:2`
lacks it — build with `xcaddy`), and the DNS API token is stored as a file-secret.

**Implementation.** Because Caddy issues one managed cert *per site-block subject*, single-app
`<host>.{$BASE_DOMAIN} { … }` blocks would each get their own cert — defeating this ADR. So the
`Caddyfile` has exactly one `*.{$BASE_DOMAIN}` site block that imports `tls_wildcard` (obtains the
wildcard) and `security_headers`; each app's route is a host-matcher **fragment**
(`@name host … / handle @name { reverse_proxy … }`) in `sites/<app>.caddy`, imported *inside* that
block via `import sites/*.caddy`. No app block, no per-app cert. Two-label zones (e.g. `*.blr`,
`*.drive`) are not covered by a single-label wildcard and each get their own dedicated wildcard block.

Related open item (proposed): baking the Caddyfile + DNS module into a versioned custom Caddy image
published to a local registry, for atomic rollouts instead of "git pull on every node." Deferred
until a local registry exists; today the `global-caddy/` directory is git-cloned to each node.
