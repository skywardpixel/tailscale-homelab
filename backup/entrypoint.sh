#!/bin/sh
# Long-running scheduler: catch up if we are overdue, then hand off to cron.
set -eu

STATE_DIR=/state
LAST_SUCCESS="$STATE_DIR/last-success"
CRON_ENV=/tmp/cron-env.sh
SCHEDULE="${BACKUP_SCHEDULE:-30 3 * * *}"
CATCHUP_AFTER_HOURS="${CATCHUP_AFTER_HOURS:-26}"

log() { echo "[backup] $*"; }

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
# cron runs jobs with a near-empty environment, so the config has to be handed
# over in a file. Written with proper single-quote escaping: RESTIC_PASSWORD is
# base64 (/, +, =) and EXCLUDE_VOLUMES contains spaces.
# ---------------------------------------------------------------------------
umask 077
: > "$CRON_ENV"
for var in RESTIC_PASSWORD RESTIC_REPOSITORY RESTIC_REPOSITORY_OFFSITE \
           AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY NTFY_URL BACKUP_HOST \
           RETENTION_DAILY RETENTION_WEEKLY RETENTION_MONTHLY \
           EXCLUDE_VOLUMES STALE_AFTER_HOURS; do
	eval "value=\${$var:-}"
	escaped=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
	printf "export %s='%s'\n" "$var" "$escaped" >> "$CRON_ENV"
done
umask 022

# ---------------------------------------------------------------------------
# Catch-up. A container scheduler has no equivalent of systemd's
# Persistent=true, so this is it: if the last success is older than the
# threshold (or there has never been one), run now instead of waiting for the
# next scheduled slot.
# ---------------------------------------------------------------------------
overdue=0
if [ ! -f "$LAST_SUCCESS" ]; then
	log "no previous successful backup recorded"
	overdue=1
else
	age_hours=$(( ($(date +%s) - $(cat "$LAST_SUCCESS")) / 3600 ))
	if [ "$age_hours" -ge "$CATCHUP_AFTER_HOURS" ]; then
		log "last success was ${age_hours}h ago (threshold ${CATCHUP_AFTER_HOURS}h)"
		overdue=1
	else
		log "last success was ${age_hours}h ago — not overdue"
	fi
fi

if [ "$overdue" -eq 1 ] && [ "${CATCHUP_ON_START:-true}" = "true" ]; then
	log "running catch-up backup now"
	# Never fatal: a failed catch-up must not turn into a container restart
	# loop that retries a broken backup forever. The healthcheck reports it.
	/usr/local/bin/run-backup.sh || log "catch-up run failed — continuing to schedule"
fi

# ---------------------------------------------------------------------------
# Hand off to cron. Job output goes to PID 1's stdout, i.e. `docker logs`,
# which Alloy already ships to Loki.
# ---------------------------------------------------------------------------
echo "$SCHEDULE . $CRON_ENV; /usr/local/bin/run-backup.sh >> /proc/1/fd/1 2>&1" > /etc/crontabs/root
chmod 0600 /etc/crontabs/root

log "schedule: '$SCHEDULE' (container timezone: ${TZ:-UTC})"
log "starting cron"
exec crond -f -d 8
