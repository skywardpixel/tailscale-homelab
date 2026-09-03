#!/bin/sh
# Backs up Docker volumes + this repo's gitignored .env files into one or more
# restic repositories.
#
# Deliberately plain restic: the repository format is exactly what the `restic`
# binary produces, so a restore never needs Docker, this image, or this script.
# See the "Restoring" section of the repo README.
set -eu

RETENTION_DAILY="${RETENTION_DAILY:-7}"
RETENTION_WEEKLY="${RETENTION_WEEKLY:-4}"
RETENTION_MONTHLY="${RETENTION_MONTHLY:-12}"

# Volumes that rebuild themselves and aren't worth storing. Space-separated
# shell globs, matched against the volume directory name.
EXCLUDE_VOLUMES="${EXCLUDE_VOLUMES:-jellyfin_cache *_caddy_data *_caddy_config}"

VOLUMES_DIR=/volumes
CONFIG_DIR=/config
# A --files-from list, not a directory of symlinks: restic archives a symlink
# as a symlink and never descends into it, which would silently produce an
# almost-empty snapshot that still passes `restic check`.
FILELIST=/tmp/backup-files.txt

log()  { echo "[backup] $*"; }
fail() { echo "[backup] ERROR: $*" >&2; }

# Best-effort failure notification through the same ntfy topic the Grafana
# alerts use. A backup that fails silently is the same as no backup at all.
notify_failure() {
	[ -n "${NTFY_URL:-}" ] || return 0
	wget -q -O /dev/null \
		--header="Title: Backup failed" \
		--header="Priority: high" \
		--header="Tags: rotating_light" \
		--post-data="restic backup on $(hostname) failed: $1" \
		"${NTFY_URL}" 2>/dev/null || true
}

on_error() {
	code=$?
	fail "aborted (exit $code) during: ${CURRENT_STEP:-startup}"
	notify_failure "${CURRENT_STEP:-startup} (exit $code)"
	exit "$code"
}
trap on_error EXIT INT TERM

: "${RESTIC_PASSWORD:?RESTIC_PASSWORD must be set — without it the repository cannot be read}"

# ---------------------------------------------------------------------------
# Work out what to back up.
#
# Every Docker volume is included by default and exclusions are explicit, so a
# service added later is protected without anyone remembering to edit a list.
# ---------------------------------------------------------------------------
CURRENT_STEP="selecting sources"
: > "$FILELIST"

excluded_count=0
included_count=0

for path in "$VOLUMES_DIR"/*; do
	[ -d "$path/_data" ] || continue
	name=$(basename "$path")

	# Anonymous volumes: 64 hex characters, created by builds and one-off runs.
	# They hold nothing anyone would restore.
	case "$name" in
		????????????????????????????????????????????????????????????????)
			if echo "$name" | grep -qE '^[0-9a-f]{64}$'; then
				excluded_count=$((excluded_count + 1))
				continue
			fi
			;;
	esac

	skip=0
	for pattern in $EXCLUDE_VOLUMES; do
		# shellcheck disable=SC2254 # pattern is a glob on purpose
		case "$name" in
			$pattern) skip=1; break ;;
		esac
	done
	if [ "$skip" -eq 1 ]; then
		excluded_count=$((excluded_count + 1))
		continue
	fi

	echo "$path/_data" >> "$FILELIST"
	included_count=$((included_count + 1))
done

if [ "$included_count" -eq 0 ]; then
	fail "no volumes selected — is /volumes mounted?"
	exit 1
fi

log "volumes: $included_count included, $excluded_count excluded"

if [ -d "$CONFIG_DIR" ]; then
	echo "$CONFIG_DIR" >> "$FILELIST"
	log "including compose config from $CONFIG_DIR (.env files are the point)"
fi

# ---------------------------------------------------------------------------
# Run against every configured target. RESTIC_REPOSITORY is the local one;
# RESTIC_REPOSITORY_OFFSITE is optional and takes the same credentials block.
# ---------------------------------------------------------------------------
run_target() {
	target_name=$1
	target_repo=$2
	export RESTIC_REPOSITORY="$target_repo"

	log "=== target: $target_name ($target_repo) ==="

	CURRENT_STEP="opening repository $target_name"
	if ! restic cat config >/dev/null 2>&1; then
		log "repository not initialised, creating it"
		restic init
	fi

	CURRENT_STEP="backup to $target_name"
	# --ignore-inode avoids spurious change detection on bind-mounted volumes.
	restic backup \
		--host "${BACKUP_HOST:-$(hostname)}" \
		--tag docker-volumes \
		--ignore-inode \
		--exclude '**/.git' \
		--exclude '**/*.sock' \
		--files-from "$FILELIST"

	CURRENT_STEP="retention on $target_name"
	restic forget \
		--tag docker-volumes \
		--keep-daily "$RETENTION_DAILY" \
		--keep-weekly "$RETENTION_WEEKLY" \
		--keep-monthly "$RETENTION_MONTHLY" \
		--prune

	CURRENT_STEP="integrity check on $target_name"
	restic check

	CURRENT_STEP="listing snapshots on $target_name"
	restic snapshots --tag docker-volumes --latest 3
	log "=== $target_name done ==="
}

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY must be set}"
PRIMARY_REPO="$RESTIC_REPOSITORY"

run_target local "$PRIMARY_REPO"

if [ -n "${RESTIC_REPOSITORY_OFFSITE:-}" ]; then
	run_target offsite "$RESTIC_REPOSITORY_OFFSITE"
else
	log "no RESTIC_REPOSITORY_OFFSITE set, skipping offsite copy"
fi

CURRENT_STEP=""
trap - EXIT
log "all targets completed successfully"
