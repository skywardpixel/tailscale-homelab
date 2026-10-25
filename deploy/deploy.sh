#!/usr/bin/env bash
# Fast-forwards this checkout to the remote branch, then redeploys the compose
# projects that need it. Run by deploy/systemd/ on a timer, or by hand. See
# deploy/README.md.
#
# A project is deployed when:
#   - changed: a file under it changed, or under a shared build it references
#     (`../_caddy-tailscale`, `../_dns-sync`, ...);
#   - drifted: a container runs a different image than compose.yaml names, or
#     is missing. This catches commits that were pulled but never deployed;
#   - rebuild day: once a week (REBUILD_WEEKDAY, or `deploy.sh --rebuild`)
#     every project with a local build is rebuilt with --pull, so floating
#     base images like caddy:2 pick up security fixes.
# Projects without a .env are not deployed on this host and are skipped.
#
# No rollback: apps migrate their data on first start, so going back is a
# manual decision (see "Upgrading" in the top-level README). On failure this
# sends an ntfy notification and stops. A container that came up unhealthy on
# the new image is not drifted, so the next run does not retry it: fix
# forward with a commit or by hand.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

if [ -f deploy/.env ]; then
	set -a
	. deploy/.env
	set +a
fi
DEPLOY_REMOTE="${DEPLOY_REMOTE:-origin}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
# Seconds to let containers start before their state is checked.
SETTLE_SECONDS="${SETTLE_SECONDS:-90}"
# ISO weekday (1 = Monday, 7 = Sunday) for the weekly rebuild; empty disables.
REBUILD_WEEKDAY="${REBUILD_WEEKDAY-7}"

rebuild=false
if [ "${1:-}" = "--rebuild" ] || [ "$(date +%u)" = "$REBUILD_WEEKDAY" ]; then
	rebuild=true
fi

log() { echo "[deploy] $*"; }

# Best-effort, like backup.sh: a broken notifier must not break the deploy.
notify() { # title priority tags message
	[ -n "${NTFY_URL:-}" ] || return 0
	curl -fsS -o /dev/null --max-time 10 \
		-H "Title: $1" -H "Priority: $2" -H "Tags: $3" \
		--data-binary "$4" "$NTFY_URL" || true
}

fail() {
	echo "[deploy] ERROR: $1" >&2
	notify "Deploy failed on $(hostname)" high rotating_light "$1"
	exit 1
}
trap 'fail "aborted at line $LINENO"' ERR

# One run at a time; a second trigger steps aside.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/homelab-deploy.lock"
flock -n 9 || { log "another deploy is running"; exit 0; }

[ "$(git symbolic-ref --short HEAD)" = "$DEPLOY_BRANCH" ] ||
	fail "checkout is not on $DEPLOY_BRANCH"
# Tracked files only; .env files are gitignored.
git diff --quiet HEAD -- || fail "checkout has uncommitted changes"

old="$(git rev-parse HEAD)"
git fetch --quiet "$DEPLOY_REMOTE" "$DEPLOY_BRANCH"
new="$(git rev-parse FETCH_HEAD)"
commits=""
changed=""
if [ "$old" != "$new" ]; then
	git merge --ff-only --quiet FETCH_HEAD ||
		fail "local $DEPLOY_BRANCH has diverged from $DEPLOY_REMOTE"
	commits="$(git log --format='%h %s' "$old..$new")"
	changed="$(git diff --name-only "$old" "$new")"
	log "fast-forwarded ${old:0:7}..${new:0:7}"
fi

# Images compose.yaml names that no container of the project runs.
drifted() { # project
	(cd "$1" && comm -23 \
		<(docker compose config --images | sort -u) \
		<(docker compose ps -a --format '{{.Image}}' | sort -u))
}

projects=()
reasons=()
for compose in */compose.yaml; do
	project="${compose%/compose.yaml}"
	[ -f "$project/.env" ] || continue
	reason=""

	deps="$project $({ grep -o '\.\./_[A-Za-z0-9_-]*' "$compose" || true; } | sed 's|^\.\./||' | sort -u | tr '\n' ' ')"
	for dir in $deps; do
		if grep -q "^$dir/" <<<"$changed"; then
			reason="changed"
			break
		fi
	done
	if [ -z "$reason" ]; then
		drift="$(drifted "$project")"
		[ -z "$drift" ] || reason="drifted: $(echo $drift)"
	fi
	if [ -z "$reason" ] && $rebuild && grep -q '^ *build:' "$compose"; then
		reason="rebuild"
	fi

	if [ -n "$reason" ]; then
		projects+=("$project")
		reasons+=("$project ($reason)")
	fi
done

if [ "${#projects[@]}" -eq 0 ]; then
	log "nothing to deploy at ${new:0:7}"
	exit 0
fi
log "deploying: ${reasons[*]}"

failed=()
for project in "${projects[@]}"; do
	log "$project: pull + up"
	if ! (cd "$project" &&
		{ ! $rebuild || docker compose build --pull --quiet; } &&
		docker compose pull --quiet --ignore-buildable &&
		docker compose up -d --build --quiet-pull); then
		failed+=("$project (compose up)")
	fi
done

sleep "$SETTLE_SECONDS"

# Unhealthy, restart-looping, or a one-shot (dns-sync) that exited non-zero.
for project in "${projects[@]}"; do
	bad="$(cd "$project" && docker compose ps -a \
		--format '{{.Service}} {{.State}} {{.Health}} {{.ExitCode}}' |
		awk '$2 == "restarting" || $3 == "unhealthy" || ($2 == "exited" && $NF != 0) { print $1 }')"
	if [ -n "$bad" ]; then
		failed+=("$project ($(echo $bad))")
	fi
done

if [ "${#failed[@]}" -gt 0 ]; then
	trap - ERR
	fail "$(printf 'Not healthy after deploy: %s\n' "${failed[@]}")
$commits"
fi

notify "Deployed on $(hostname)" low package "$(printf '%s\n' "${reasons[@]}")
$commits"
log "done"
