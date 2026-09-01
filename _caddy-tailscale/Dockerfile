# Shared Caddy build, reused by every <service>/compose.yaml in this repo
# (each one does `build: {context: ../_caddy-tailscale}`).
#
# Adds:
#   - tailscale/caddy-tailscale: join the tailnet directly via tsnet
#     (userspace — no NET_ADMIN/tun, no host networking) and auto-issue
#     certs for <hostname>.<tailnet>.ts.net.
#   - caddy-dns/cloudflare: DNS-01 challenge, for certs on custom domains
#     that Caddy can't prove ownership of via inbound HTTP-01/TLS-ALPN-01
#     (this Caddy has no public listener, only a tailnet one).
#
# Rebuild after bumping versions or when a service's `docker compose build`
# picks up a stale layer:
#   docker compose build caddy
FROM caddy:2-builder AS builder

RUN xcaddy build \
    --with github.com/tailscale/caddy-tailscale \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
