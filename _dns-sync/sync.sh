#!/usr/bin/env bash
# Ensure the tailnet-only DNS record for ${CUSTOM_DOMAIN} exists in Cloudflare,
# as a DNS-only CNAME to this node's MagicDNS name
# (${TS_HOSTNAME}.${TAILNET_NAME}.ts.net).
#
# Replaces the manual "add a grey-cloud A record pointing at the node's
# Tailscale IP" step. A CNAME to the MagicDNS name never needs updating when the
# node IP changes, and resolves for tailnet devices exactly like the A record
# did (and, like it, not at all off-tailnet — which is the point).
#
# Idempotent: run it on every `docker compose up`. Only writes to Cloudflare
# when the record is missing or wrong.
set -euo pipefail

: "${CF_API_TOKEN:?set in .env}"
: "${CUSTOM_DOMAIN:?set in .env}"
: "${TS_HOSTNAME:?set in .env}"
: "${TAILNET_NAME:?set in .env}"

target="${TS_HOSTNAME}.${TAILNET_NAME}.ts.net"
api="https://api.cloudflare.com/client/v4"

cf() {
	curl -sS --fail-with-body \
		-H "Authorization: Bearer ${CF_API_TOKEN}" \
		-H "Content-Type: application/json" "$@"
}

# Walk up the labels of CUSTOM_DOMAIN until one matches an active zone, so this
# works whether the zone is example.com or a delegated sub.example.com.
zone_id=""
name="$CUSTOM_DOMAIN"
while [ -n "$name" ]; do
	zone_id=$(cf "${api}/zones?name=${name}&status=active" | jq -r '.result[0].id // empty')
	[ -n "$zone_id" ] && break
	case "$name" in
		*.*.*) name="${name#*.}" ;;
		*) name="" ;;
	esac
done
[ -n "$zone_id" ] || { echo "dns-sync: no Cloudflare zone found for ${CUSTOM_DOMAIN}" >&2; exit 1; }

existing=$(cf "${api}/zones/${zone_id}/dns_records?name=${CUSTOM_DOMAIN}")
count=$(echo "$existing" | jq -r '.result | length')

if [ "$count" = "1" ] \
	&& [ "$(echo "$existing" | jq -r '.result[0].type')" = "CNAME" ] \
	&& [ "$(echo "$existing" | jq -r '.result[0].content')" = "$target" ]; then
	echo "dns-sync: up to date — CNAME ${CUSTOM_DOMAIN} -> ${target}"
	exit 0
fi

# A CNAME can't coexist with other records at the same name, so clear whatever
# is there (the old A record, a stale CNAME) before creating ours.
for id in $(echo "$existing" | jq -r '.result[].id'); do
	cf -X DELETE "${api}/zones/${zone_id}/dns_records/${id}" >/dev/null
	echo "dns-sync: removed stale record ${id}"
done

cf -X POST "${api}/zones/${zone_id}/dns_records" --data "$(
	jq -nc --arg n "$CUSTOM_DOMAIN" --arg c "$target" \
		'{type:"CNAME", name:$n, content:$c, ttl:1, proxied:false}'
)" >/dev/null
echo "dns-sync: set CNAME ${CUSTOM_DOMAIN} -> ${target}"
