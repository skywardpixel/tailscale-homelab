#!/bin/sh
# Unhealthy when no backup has succeeded recently.
#
# This is the check a systemd timer does not give you for free: it catches
# "backups quietly stopped weeks ago", which is a far more common failure than
# a single missed window. The container being up proves only that cron is
# alive, not that anything was actually backed up.
set -eu

LAST_SUCCESS=/state/last-success
STALE_AFTER_HOURS="${STALE_AFTER_HOURS:-48}"

if [ ! -f "$LAST_SUCCESS" ]; then
	echo "no successful backup recorded yet"
	exit 1
fi

age_hours=$(( ($(date +%s) - $(cat "$LAST_SUCCESS")) / 3600 ))
if [ "$age_hours" -ge "$STALE_AFTER_HOURS" ]; then
	echo "last success was ${age_hours}h ago (limit ${STALE_AFTER_HOURS}h)"
	exit 1
fi

echo "last success ${age_hours}h ago"
