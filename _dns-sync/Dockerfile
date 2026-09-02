# Shared one-shot, reused by every <service>/compose.yaml as the `dns-sync`
# service (each does `build: {context: ../_dns-sync}`).
#
# Ensures ${CUSTOM_DOMAIN} resolves to this node over the tailnet by keeping a
# DNS-only CNAME to ${TS_HOSTNAME}.${TAILNET_NAME}.ts.net in Cloudflare. Runs to
# completion and exits; safe to re-run on every `docker compose up`.
FROM alpine:3.24

RUN apk add --no-cache bash curl jq

COPY sync.sh /usr/local/bin/sync.sh
RUN chmod +x /usr/local/bin/sync.sh

ENTRYPOINT ["/usr/local/bin/sync.sh"]
