#!/usr/bin/env bash
# Maintain a DNS-only A record for the Caddy node's stable Tailscale IPv4.
# TS_IPV4 belongs to the service's tsnet node, not the Docker host.
# Run on startup and after changing TS_IPV4 when replacing a node.
set -euo pipefail

: "${CF_API_TOKEN:?set in .env}"
: "${CUSTOM_DOMAIN:?set in .env}"
: "${TS_IPV4:?set to the Caddy node Tailscale IPv4 in .env}"

target="$TS_IPV4"
# Reject malformed addresses and addresses outside Tailscale's IPv4 range
# before any Cloudflare calls or changes.
jq -en --arg ip "$target" '
  ($ip | split(".")) as $parts |
  ($parts | length) == 4 and
  all($parts[]; test("^(0|[1-9][0-9]{0,2})$")) and
  (($parts | map(tonumber)) as $octets |
  $octets[0] == 100 and $octets[1] >= 64 and $octets[1] <= 127 and
  all($octets[]; . >= 0 and . <= 255))
' >/dev/null || { echo "dns-sync: TS_IPV4 must be an IPv4 address in 100.64.0.0/10" >&2; exit 1; }
api="https://api.cloudflare.com/client/v4"

cf() {
	local response
	response=$(curl -sS --fail-with-body --connect-timeout 10 --max-time 30 \
		-H "Authorization: Bearer ${CF_API_TOKEN}" \
		-H "Content-Type: application/json" "$@") || return
	if ! jq -e '.success == true' <<<"$response" >/dev/null; then
		echo "dns-sync: Cloudflare API rejected the request" >&2
		return 1
	fi
	printf '%s\n' "$response"
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
# Only manage address records and the old CNAME; preserve TXT/MX/etc.
managed=$(jq -c '[.result[] | select(.type == "A" or .type == "AAAA" or .type == "CNAME")]' <<<"$existing")
count=$(jq 'length' <<<"$managed")
payload=$(jq -nc --arg n "$CUSTOM_DOMAIN" --arg c "$target" \
  '{type:"A", name:$n, content:$c, ttl:1, proxied:false}')

if [ "$count" = 1 ] && jq -e --arg ip "$target" \
  '.[0] | .type == "A" and .content == $ip and .proxied == false' <<<"$managed" >/dev/null; then
	echo "dns-sync: up to date — A ${CUSTOM_DOMAIN} -> ${target}"
	exit 0
fi

# Refuse ambiguous record sets instead of deleting potentially intentional
# addresses. The normal migration is one CNAME -> one A, updated in place.
if [ "$count" -gt 1 ] || jq -e 'any(.[]; .type == "AAAA")' <<<"$managed" >/dev/null; then
	echo "dns-sync: conflicting address records for ${CUSTOM_DOMAIN}; review them before retrying" >&2
	exit 1
fi

if [ "$count" = 1 ]; then
	id=$(jq -r '.[0].id' <<<"$managed")
	cf -X PUT "${api}/zones/${zone_id}/dns_records/${id}" --data "$payload" >/dev/null
else
	cf -X POST "${api}/zones/${zone_id}/dns_records" --data "$payload" >/dev/null
fi
echo "dns-sync: set A ${CUSTOM_DOMAIN} -> ${target}"
