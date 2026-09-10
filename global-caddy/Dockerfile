# Custom Caddy build with the Cloudflare DNS module — required for DNS-01 wildcard issuance
# (stock caddy:2 has no DNS provider). See ADR-0005 and README.md.
FROM caddy:2.10-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2.10

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
