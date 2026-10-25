# Deploy

[Back to overview](../README.md) · [Upgrades and rollback](../README.md#upgrading)

`deploy.sh` fast-forwards this checkout to `main` and redeploys the compose
projects that need it. A systemd user timer runs it every day
at 05:00, after the 03:30 backup, so a snapshot from before each upgrade
exists. Together with Renovate's patch automerge, patch releases go live
without you; minor and major ones go live the morning after you merge the PR.

## What it does

1. Stops with a notification if the checkout is not on `main` or has
   uncommitted changes to tracked files. Local tweaks belong in a gitignored
   `compose.override.yaml`.
2. Fetches and fast-forwards. Nothing new: exits quietly.
3. Picks the projects to deploy. Projects without a `.env` are not set up on
   this host and are skipped. The others are deployed when:
   - **changed**: a file under the project changed, or under a shared build it
     references (`_caddy-tailscale`, `_dns-sync`, `_media-exporter`);
   - **drifted**: a container runs a different image than `compose.yaml`
     names, or is missing. This catches commits that were pulled but never
     deployed, and a project you stopped by hand;
   - **rebuild day** (Sunday, `REBUILD_WEEKDAY`): every project with a local
     build. These start from tags that move (`caddy:2`), so without a rebuild
     Caddy and its Tailscale plugin never get security fixes.
     `./deploy.sh --rebuild` does it on any day.
4. For each: `docker compose build --pull` on rebuild day, then
   `docker compose pull --ignore-buildable` and `docker compose up -d --build`.
5. Waits `SETTLE_SECONDS` (90), then fails the run if any container of those
   projects is unhealthy, restarting, or a one-shot that exited non-zero.
6. Sends an ntfy notification: low priority with the commits it deployed, or
   high priority with what failed.

It never rolls back. Apps migrate their data on first start, and going back
is a choice to make with the release notes in hand — see
[Upgrading](../README.md#upgrading) and [restoring](../backup/README.md#restoring).
A container that came up unhealthy on the new image is not drifted, so the
next run does not retry it: fix it by hand, or push a fix.

## Setup

On the host, as the user that owns this checkout (must be in the `docker`
group), from `deploy/`:

```sh
cp .env.example .env              # set NTFY_URL; see DEPLOY_REMOTE below
./deploy.sh                       # one run by hand first
systemctl --user link "$PWD/systemd/homelab-deploy.service"
systemctl --user enable --now "$PWD/systemd/homelab-deploy.timer"
sudo loginctl enable-linger "$USER"   # so the timer runs while logged out
```

Check it with `systemctl --user list-timers` and
`journalctl --user -u homelab-deploy`.

The timer has no SSH agent. If `origin` is an SSH URL with a
passphrase-protected key, set `DEPLOY_REMOTE` to the repo's HTTPS URL in
`.env`; the repo is public, so no credentials are needed.

A project you stopped on purpose (`docker compose down`) counts as drifted
and is started again. To keep it down, move its `.env` aside.

To pause automatic deploys: `systemctl --user stop homelab-deploy.timer`
(`disable` to keep it off across reboots).
