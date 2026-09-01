#!/usr/bin/env bash
# One-time migration of the native Debian Jellyfin install into the
# Docker-based project in this directory.
#
# Needs root: it reads /var/lib/jellyfin and /etc/jellyfin (root-only) and
# stops the system service.
#
#   sudo ./migrate.sh
#
# After it finishes: fill in ./.env, then `docker compose up -d`.

set -euo pipefail
cd "$(dirname "$0")"

# Pick up JELLYFIN_UID / JELLYFIN_GID from .env if present.
if [[ -f .env ]]; then set -a; . ./.env; set +a; fi
JF_UID="${JELLYFIN_UID:-103}"
JF_GID="${JELLYFIN_GID:-105}"

if [[ $EUID -ne 0 ]]; then
	echo "Run me with sudo." >&2
	exit 1
fi

echo ">> Stopping and disabling native jellyfin.service"
systemctl stop jellyfin
systemctl disable jellyfin

echo ">> Creating docker volumes"
docker volume create jellyfin_data   >/dev/null
docker volume create jellyfin_config >/dev/null
docker volume create jellyfin_cache  >/dev/null

echo ">> Copying /var/lib/jellyfin -> jellyfin_data (this can take a while)"
docker run --rm \
	-v /var/lib/jellyfin:/src:ro \
	-v jellyfin_data:/dst \
	alpine sh -c "cp -a /src/. /dst/ && mkdir -p /dst/log && chown -R ${JF_UID}:${JF_GID} /dst"

echo ">> Copying /etc/jellyfin -> jellyfin_config"
docker run --rm \
	-v /etc/jellyfin:/src:ro \
	-v jellyfin_config:/dst \
	alpine sh -c "cp -a /src/. /dst/ && chown -R ${JF_UID}:${JF_GID} /dst"

echo ">> Preparing jellyfin_cache (starts empty; transcodes/images regenerate)"
docker run --rm \
	-v jellyfin_cache:/dst \
	alpine sh -c "chown -R ${JF_UID}:${JF_GID} /dst"

echo
echo ">> Migration copy complete."
echo "   Native Jellyfin is stopped and disabled; its files are untouched."
echo "   Next: fill in ./.env, then  docker compose up -d"
