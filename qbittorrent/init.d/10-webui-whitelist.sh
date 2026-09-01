#!/usr/bin/with-contenv bash
# Runs (as root, before qBittorrent starts) via LinuxServer's
# /custom-cont-init.d hook. Ensures the WebUI auth-subnet whitelist is set so
# clients on the shared `downloads` network (e.g. AutoBangumi) can call the
# API without credentials, while everything else — including the Caddy front —
# still needs to log in.
set -e
CONF=/config/qBittorrent/qBittorrent.conf
SUBNET="${WEBUI_WHITELIST_SUBNET:-172.28.0.0/16}"

mkdir -p "$(dirname "$CONF")"
touch "$CONF"
grep -q '^\[Preferences\]' "$CONF" || printf '\n[Preferences]\n' >> "$CONF"

if ! grep -q 'WebUI\\AuthSubnetWhitelistEnabled' "$CONF"; then
	sed -i "/^\[Preferences\]/a WebUI\\\\AuthSubnetWhitelistEnabled=true\nWebUI\\\\AuthSubnetWhitelist=${SUBNET}" "$CONF"
fi
