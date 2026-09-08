# Backups

[Back to overview](../README.md)

Run Compose commands from `backup/`. Host restic commands can run from any
directory.

This project snapshots every Docker volume worth keeping, plus this repo's
gitignored `.env` files, into a [restic](https://restic.net/) repository. It
schedules itself, so it comes up like every other project here:

```sh
cp .env.example .env      # then edit — see the password warning below
docker compose up -d
docker compose logs -f backup
```

To run one immediately without waiting for the schedule:

```sh
docker compose exec backup /usr/local/bin/run-backup.sh
```

**The repository is plain restic on purpose.** Nothing in this directory is
needed to read it back: a restore needs only the `restic` binary, so a broken
Docker install is not also a lost backup. That is the whole reason the
container is confined to *scheduling and orchestration*.

## What is in it

Every named volume is included **by default** and exclusions are explicit, so a
service added later is protected without anyone remembering to update a list.
Anonymous volumes (64 hex characters, left behind by builds) are always
skipped. `EXCLUDE_VOLUMES` drops the rest that rebuild themselves:

- `jellyfin_cache` and the caddy cert/config volumes — regenerated on demand.
- `backup_state` — this project's own last-success timestamp.
- `monitoring_*_data` — the observability stores. Prometheus metrics, Loki
  logs, Alloy's WAL and Grafana's own database. None of it is worth restoring:
  the dashboards, datasources and alert rules are provisioned from this repo
  and therefore already captured via `/config`, Grafana's 53 MB is mostly
  re-downloadable plugins, and metrics history from before a disaster has
  little value after it. The glob deliberately does not match
  `monitoring_tailscale_state`, which is node identity worth keeping.

That leaves the volumes worth keeping — ~170 MiB when this was measured,
dominated by `jellyfin_config` (watch history and library metadata) and now
also carrying `audiobookshelf_config`, which holds listening progress. Those
are the things here that are genuinely painful to rebuild, and the total is
small enough to run nightly without thinking about it.

`..` is mounted at `/config` so the `.env` files come along. They are gitignored
and exist nowhere else, so without them a rebuild means reissuing every
Tailscale auth key and Cloudflare token.

## The password

`RESTIC_PASSWORD` in `.env` is the single most important value here.
Restic has **no recovery path** — lose it and every snapshot is permanently
unreadable. Put a copy in a password manager before the first run.

Note that `.env` is itself inside the backup, which is a convenience for
a partial restore and **not** a recovery path: you need the password to decrypt
the repository that contains the password.

## Consistency caveat

Volumes are copied hot, with nothing stopped. For plain files that is fine.
`jellyfin.db` and Audiobookshelf's `absdatabase.sqlite` are SQLite, so a
snapshot taken mid-write may not open cleanly — which is why retention keeps 7
dailies rather than relying on the newest one. In practice the 03:30 window is
when nothing is streaming.

For a consistent copy, stop services that write to the volumes before running
a backup, and restart them after it finishes. This causes downtime for those
services; the default backup schedule does not stop them.

Grafana used to be the other hot-SQLite case; it is now excluded entirely for
the reasons above. Restoring onto a fresh Grafana reprovisions the dashboards,
datasources and alert rules from this repo, and the admin password comes from
the backed-up `monitoring/.env` — so the rebuilt state is complete.

## Scheduling

The container runs busybox cron on `BACKUP_SCHEDULE` (default `30 3 * * *`, in
`TZ`), so there is no host unit to install and no root needed. Three pieces
cover what an external timer would otherwise provide:

- **Catch-up.** On start, if the last success is older than
  `CATCHUP_AFTER_HOURS` (default 26), it backs up immediately instead of
  waiting for the next slot. That is systemd's `Persistent=true`, for a host
  that was powered off.
- **Staleness healthcheck.** The container reports unhealthy once nothing has
  succeeded within `STALE_AFTER_HOURS` (default 48). A systemd timer gives you
  no equivalent, and "backups quietly stopped weeks ago" is a far more common
  failure than a single missed window. `docker ps` shows it, and the monitoring
  stack sees it like any other unhealthy container.
- **Overlap protection.** Runs take an exclusive `flock`, so a slow run never
  has a second started on top of it — the later trigger steps aside.

Failures POST to the same ntfy topic the Grafana alerts use — set `NTFY_URL` in
`.env`, because a backup that fails silently is the same as no backup.

[systemd/](systemd/) still holds timer units for hosts that would rather schedule
this externally; they are a documented fallback, not part of the normal setup.

This runs **alongside** the host's existing `restic-backup.timer` (Sun 03:00,
repo at `/mnt/data/restic`) and writes to a separate repository at
`/mnt/data/restic-docker`. Retire the old one once you have restored from this
one and are satisfied.

## Restoring

Inspect and restore with the host's `restic` — no Docker involved:

```sh
sudo restic -r /mnt/data/restic-docker snapshots
sudo restic -r /mnt/data/restic-docker restore latest --target /tmp/restore

# or a single volume
sudo restic -r /mnt/data/restic-docker restore latest \
  --target /tmp/restore --include /volumes/jellyfin_config/_data
```

Then stop the service, replace the volume contents, and start it again. Paths
inside a snapshot are `/volumes/<volume-name>/_data/...` and `/config/...`.

## Adding an offsite copy

`/mnt/data` is a disk in the same machine, so it does not survive a drive
failure or a bad `docker volume prune`. The script already loops over targets —
set these in `.env` and the next run writes both:

```sh
RESTIC_REPOSITORY_OFFSITE=s3:https://<account-id>.r2.cloudflarestorage.com/<bucket>
AWS_ACCESS_KEY_ID=<r2 access key id>
AWS_SECRET_ACCESS_KEY=<r2 secret access key>
```

An R2 bucket plus an API token with **Object Read & Write** is all it needs. At
~320 MiB with deduplication, it costs essentially nothing, and the same
`RESTIC_PASSWORD` encrypts both targets.
