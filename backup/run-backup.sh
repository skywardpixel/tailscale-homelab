#!/bin/sh
# One backup run: serialised, deprioritised, and recorded on success.
#
# Split out from backup.sh so the same run can be triggered three ways — by
# cron, by the startup catch-up, or by hand — without duplicating the locking
# and bookkeeping.
set -eu

STATE_DIR=/state
LAST_SUCCESS="$STATE_DIR/last-success"
LOCK=/tmp/backup.lock

mkdir -p "$STATE_DIR"

# A slow run must never have a second one started on top of it. Non-blocking:
# if the previous run is still going, this one steps aside rather than queuing.
exec 9>"$LOCK"
if ! flock -n 9; then
	echo "[backup] a previous run is still in progress — skipping this trigger"
	exit 0
fi

# Backups are never worth competing with a Jellyfin transcode for.
nice -n 10 ionice -c 3 /usr/local/bin/backup.sh

# Only reached when backup.sh exits 0 — its own trap aborts on failure, so a
# failed run deliberately leaves the timestamp stale for the healthcheck.
date +%s > "$LAST_SUCCESS"
echo "[backup] recorded success at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
