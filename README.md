# tailscale-homelab

Docker Compose projects for self-hosted services, each fronted by its own
[Caddy](https://caddyserver.com/) + [Tailscale](https://tailscale.com/) node
so the web UI is reachable only over the tailnet, on HTTPS, with nothing
bound to a host port (bar the odd non-UI port like BitTorrent's).

| Project          | Image                               | Reachable at                              |
|------------------|-------------------------------------|-------------------------------------------|
| `audiobookshelf` | `ghcr.io/advplyr/audiobookshelf`    | `<host>.<tailnet>.ts.net` + custom domain |
| `autobangumi`    | `ghcr.io/estrellaxd/auto_bangumi`   | `<host>.<tailnet>.ts.net` + custom domain |
| `jellyfin`       | `jellyfin/jellyfin`                 | `<host>.<tailnet>.ts.net` + custom domain |
| `qbittorrent`    | `lscr.io/linuxserver/qbittorrent`   | `<host>.<tailnet>.ts.net` + custom domain |
| `monitoring`     | Grafana + Prometheus + Loki + Alloy | `<host>.<tailnet>.ts.net` + custom domain |
| `backup`         | `restic/restic`                     | no web UI — self-scheduling restic backup |

Each project is a directory with a `compose.yaml`, a `Caddyfile`, and an
`.env.example`. Copy `.env.example` to `.env` (gitignored) and fill it in —
`docker compose` reads `.env` automatically. No secrets are committed.

## How the Caddy + Tailscale front works

`_caddy-tailscale/` holds one shared `Dockerfile`: Caddy built with
[`xcaddy`](https://github.com/caddyserver/xcaddy) plus two plugins —
[`tailscale/caddy-tailscale`](https://github.com/tailscale/caddy-tailscale)
and [`caddy-dns/cloudflare`](https://github.com/caddy-dns/cloudflare). Every
project builds its `caddy` service from `../_caddy-tailscale` and tags the
result `services/caddy-tailscale:local`.

Per project you get two containers: the app (no published ports) and a `caddy`
sidecar that:

- joins the tailnet itself via `tsnet` — userspace, so no `NET_ADMIN`, no
  `/dev/net/tun`, no host networking;
- serves `${TS_HOSTNAME}.${TAILNET_NAME}.ts.net` with a cert minted by
  Tailscale (`tls { get_certificate tailscale }` — this must be explicit;
  without it Caddy tries public Let's Encrypt, which can't validate a
  tailnet-only listener);
- serves `${CUSTOM_DOMAIN}` with a Let's Encrypt cert obtained via the
  Cloudflare DNS-01 challenge (works for a private name because DNS-01 needs
  no inbound reachability);
- reverse-proxies both to the app over the project's compose network.

A second shared build, `_dns-sync/`, is wired into each project as a one-shot
`dns-sync` service. On every `up` it ensures Cloudflare holds a **DNS-only
`A` record `${CUSTOM_DOMAIN}` → `${TS_IPV4}`**. Set `TS_IPV4` in each project's
`.env` to that service's Caddy node address from the Tailscale admin console,
not the Docker host's address. Tailscale IPs remain stable while node identity
is preserved in `tailscale_state`; update `TS_IPV4` if the node is replaced.

A records avoid client-specific NXDOMAIN failures when public CNAMEs point
into private MagicDNS (`.ts.net`). The sync converts a single existing CNAME
in place, preserves unrelated records, and exits without writes when already
correct. Conflicting address records require manual review.

### Prerequisites

- A tailnet with **HTTPS Certificates** enabled (Admin console → DNS).
- One Tailscale auth key **per node** (non-ephemeral). Node identity then
  persists in the `tailscale_state` volume across restarts.
- A Cloudflare API token with **Zone → DNS → Edit** (plus **Zone → Zone →
  Read**, which the "Edit zone DNS" template already includes) for the zone
  behind `${CUSTOM_DOMAIN}`. One token can cover multiple services in the same
  zone. Used for both the ACME DNS-01 challenge and the `dns-sync` service.

The custom-domain DNS record is created and kept current by the `dns-sync`
service — no manual record needed. The name resolves publicly, but the
service remains reachable only through the tailnet. Resolvers with DNS
rebinding protection may need an exception for this domain.

## Bring up a project

```sh
cd <project>
cp .env.example .env      # then edit .env
docker compose up -d              # also runs dns-sync once (creates the A record)
docker compose logs -f caddy      # watch the tailnet join + cert issuance
```

`dns-sync` runs as part of `up` and exits; check it with
`docker compose logs dns-sync`, or re-run it on its own with
`docker compose run --rm dns-sync`.

To migrate an existing installation, set `TS_IPV4` for each project, then run
`docker compose build dns-sync` and `docker compose run --rm dns-sync` in that
project. This updates the existing CNAME to an A record without restarting
Caddy. Allow cached NXDOMAIN responses to expire or flush the affected
client's DNS cache before retesting.

Restart / tear down:

```sh
docker compose restart caddy   # reload Caddyfile changes
docker compose down            # stop (volumes kept)
```

## Upgrading

Image versions are **pinned** to an explicit tag in each `compose.yaml`
(`image: name:1.2.3`) — not `latest` — so a rebuild or a fresh host gets the
exact stack that was last tested. `docker compose pull` on a pinned tag still
picks up base-OS security rebuilds (LinuxServer republishes the `X.Y.Z`
qBittorrent tag; that's why it's pinned to the short tag, not the
`…_v2.0.14-lsNNN` form). To try a different version without editing a tracked
file, drop the override in a `compose.override.yaml` (gitignored).

[Renovate](https://docs.renovatebot.com/) watches the pinned tags —
`compose.yaml` images and the two `Dockerfile`s — and opens one PR per update
with a link to the changelog. Nothing updates on its own.

It runs **self-hosted** from `.github/workflows/renovate.yml` (a scheduled
GitHub Action, no Mend app). One-time setup: create a fine-grained PAT scoped
to this repo with **Contents / Pull requests / Issues / Workflows: Read and
write**, add it as the `RENOVATE_TOKEN` Actions secret. The workflow runs
Monday mornings, or on demand via *Actions → Renovate → Run workflow*.
`renovate.json` holds the rules; a "Dependency Dashboard" issue tracks
everything pending.

To take an update:

```sh
# merge the Renovate PR on GitHub, then on the host:
git pull
cd <project>
docker compose pull                  # app images (skips the built ones)
docker compose up -d --build         # --build picks up _caddy-tailscale / _dns-sync changes
docker compose logs -f               # healthcheck green, WebUI loads, one real task works
```

Rolling back means checking out the previous tag and `up -d` again — but the
app may have migrated its own database/config in the volume on first start
(qBittorrent does this), and those migrations are not always reversible. Read
the release notes before a major bump; snapshot the `config` volume first if
it's one you can't recreate.

## Backups

`backup/` snapshots every Docker volume worth keeping, plus this repo's
gitignored `.env` files, into a [restic](https://restic.net/) repository. It
schedules itself, so it comes up like every other project here:

```sh
cd backup
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

### What is in it

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

### The password

`RESTIC_PASSWORD` in `backup/.env` is the single most important value here.
Restic has **no recovery path** — lose it and every snapshot is permanently
unreadable. Put a copy in a password manager before the first run.

Note that `backup/.env` is itself inside the backup, which is a convenience for
a partial restore and **not** a recovery path: you need the password to decrypt
the repository that contains the password.

### Consistency caveat

Volumes are copied hot, with nothing stopped. For plain files that is fine.
`jellyfin.db` and Audiobookshelf's `absdatabase.sqlite` are SQLite, so a
snapshot taken mid-write may not open cleanly — which is why retention keeps 7
dailies rather than relying on the newest one. In practice the 03:30 window is
when nothing is streaming.

If you want a guaranteed-consistent copy, `backup/systemd/docker-backup.service`
carries commented-out `ExecStartPre`/`ExecStartPost` lines that stop and start
Jellyfin around the run. It costs a few seconds of downtime at 03:30 and is
off by default because it interrupts anyone still watching.

Grafana used to be the other hot-SQLite case; it is now excluded entirely for
the reasons above. Restoring onto a fresh Grafana reprovisions the dashboards,
datasources and alert rules from this repo, and the admin password comes from
the backed-up `monitoring/.env` — so the rebuilt state is complete.

### Scheduling

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
`backup/.env`, because a backup that fails silently is the same as no backup.

`backup/systemd/` still holds timer units for hosts that would rather schedule
this externally; they are a documented fallback, not part of the normal setup.

This runs **alongside** the host's existing `restic-backup.timer` (Sun 03:00,
repo at `/mnt/data/restic`) and writes to a separate repository at
`/mnt/data/restic-docker`. Retire the old one once you have restored from this
one and are satisfied.

### Restoring

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

### Adding an offsite copy

`/mnt/data` is a disk in the same machine, so it does not survive a drive
failure or a bad `docker volume prune`. The script already loops over targets —
set these in `backup/.env` and the next run writes both:

```sh
RESTIC_REPOSITORY_OFFSITE=s3:https://<account-id>.r2.cloudflarestorage.com/<bucket>
AWS_ACCESS_KEY_ID=<r2 access key id>
AWS_SECRET_ACCESS_KEY=<r2 secret access key>
```

An R2 bucket plus an API token with **Object Read & Write** is all it needs. At
~320 MiB with deduplication, it costs essentially nothing, and the same
`RESTIC_PASSWORD` encrypts both targets.

## Audiobookshelf notes

One host path, mounted read-only:

- `AUDIOBOOKS_DIR` → `/audiobooks`, **read-only**. Audiobookshelf keeps cover
  art and its scan results in the `metadata` volume, so it never needs to
  write into the library. Drop the `:ro` if you want the web uploader, or
  *Settings → Item Metadata Utils → "Store metadata with item"*, which moves
  those files out of `/metadata/items` and into the library folders.
- `PODCASTS_DIR` — **removed.** Audiobookshelf writes podcast episodes into
  its podcast folder, which would be the only writable host path here. With no
  podcast library in use, the mount was dead weight and has been dropped.

Create the audiobooks directory before the first `up` — Docker auto-creates a
missing bind-mount source as `root:root`, which you then cannot write to
without `sudo`:

```sh
sudo mkdir -p /mnt/downloads/audiobooks
sudo chown "$USER":"$USER" /mnt/downloads/audiobooks
```

### Why it runs as the image's default user

It didn't always. An earlier version ran the app as a dedicated `audiobookshelf`
uid, with a one-shot `init` service to chown the named volumes first — because
a freshly created volume is `root:root 0755` and non-root Audiobookshelf dies
on it with `EACCES: mkdir '/metadata/logs'`.

That whole apparatus existed for one reason: container root writing podcast
episodes onto `/mnt/downloads`, which is ext4 mounted without `nosuid`. Since
no podcast library is in use, that mount is gone, and with it the only writable
host path — the library itself is `:ro`, and everything else the app writes
lands in its own Docker volumes. So the `user:` override and the `init` service
were both removed as machinery guarding a risk that no longer exists.

**Bring it back if either of these changes:** you add a podcast library, or you
make `AUDIOBOOKS_DIR` read-write for the web uploader. Both reintroduce a
writable host path. The removed setup is in the git history — see the commit
that added it, and the one that took it out.

Add `/audiobooks` as the library folder in the first-run wizard.

Two Docker-managed volumes, and the split matters for restores:

- `config` — the SQLite database: users, libraries, and **listening
  progress**. The one thing here that genuinely cannot be recreated.
- `metadata` — cover art, cached transcodes, and Audiobookshelf's own internal
  backups. Rebuildable, but a rescan re-matches everything from scratch, so
  it's left in the restic backup. If it ever grows past what you want to
  snapshot nightly, add `audiobookshelf_metadata` to `EXCLUDE_VOLUMES`.

No GPU block, unlike Jellyfin: the image ships `ffmpeg` and audio transcoding
is cheap on CPU.

Nothing extra is needed in the Caddyfile — Caddy passes Audiobookshelf's
socket.io connection through as a normal WebSocket upgrade, and puts no limit
on request bodies, so large uploads work if you make the library writable.

**On a phone**, note there is no official Audiobookshelf iOS app — the
official app is Android-only. On iOS the usable clients are third-party:
SoundLeaf (offline downloads free in its base tier) and Plappa (downloads
behind a one-time purchase). Whichever you use, it reaches `${CUSTOM_DOMAIN}`
only while the Tailscale app is connected, since the address is tailnet-only. Downloading books to the device for
offline playback is the way around that, not a public listener.

## Samba shares

Not part of this repo's compose projects: `smbd`/`nmbd` run on the host
(Debian's `samba` package) and the shares live in `/etc/samba/smb.conf`. They
are recorded here because that file is **not** covered by the backup — which
snapshots Docker volumes and this repo, not `/etc`.

| Share        | Path                        | Access                         |
|--------------|-----------------------------|--------------------------------|
| `anime`      | `/mnt/downloads/anime`      | read-only, `kyleyan` can write |
| `tvshows`    | `/mnt/downloads/tv-shows`   | read-only, `kyleyan` can write |
| `audiobooks` | `/mnt/downloads/audiobooks` | read-only, `kyleyan` can write |

`audiobooks` is how books actually get onto the server: Audiobookshelf mounts
that directory `:ro`, so the web uploader is not the path in. Each share
follows the same shape:

```ini
[audiobooks]
   comment = Audiobooks
   path = /mnt/downloads/audiobooks
   browseable = yes
   read only = yes
   guest ok = no
   write list = kyleyan
```

Apply a change with `sudo testparm -s` first, then
`sudo systemctl reload smbd`. A share needs a Samba password separate from the
Unix one — `sudo smbpasswd -a kyleyan` if it was never set.

**These shares are reachable from the LAN, not just the tailnet** — `smbd`
binds `0.0.0.0:445`, unlike every compose project here. That is a deliberate
difference if you mount them from a device that isn't on the tailnet; to close
it, add to `[global]` and reload:

```ini
   interfaces = lo tailscale0
   bind interfaces only = yes
```

## Jellyfin notes

`MEDIA_DIR` (host path) is mounted read-only at `/media`; point libraries at
`/media/<subfolder>` in the first-run wizard. `config` and `cache` are
Docker-managed volumes.

GPU transcoding needs the **NVIDIA container toolkit** on the host:

```sh
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update && sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

For an Intel/AMD iGPU instead: drop the `deploy:` block from
`jellyfin/compose.yaml`, add `devices: [/dev/dri:/dev/dri]`, and add a
`group_add` for the host's `render` group.

After first-run setup, in the Jellyfin web UI:

- **Dashboard → Playback**: enable NVENC hardware acceleration, then force a
  transcode and check `nvidia-smi` on the host shows an `ffmpeg` process.
- **Dashboard → Networking**: add the `caddy` container to *Known proxies*
  (`docker compose exec caddy hostname -i`) so client IPs are logged.

## qBittorrent + AutoBangumi

AutoBangumi drives qBittorrent's API. They talk over a shared external Docker
network so the call stays internal (no round-trip through the tailnet):

```sh
docker network create --subnet 172.28.0.0/16 downloads
```

Both `qbittorrent/compose.yaml` and `autobangumi/compose.yaml` attach to it;
AutoBangumi's downloader host is `qbittorrent:8080` (`ssl: false`). The
monitoring project's `media-exporter` joins it too, which is how it scrapes the
qBittorrent API without credentials. There is a second shared network, `media`
(`docker network create media`), joining Jellyfin to that same exporter.

**Auth:** `qbittorrent/init.d/10-webui-whitelist.sh` (run by the LinuxServer
image before qBittorrent starts) adds that subnet to qBittorrent's
*WebUI → auth subnet whitelist*, so clients on the `downloads` network reach
the API without credentials. Everything else — including the Caddy front, on
a different subnet — still has to log in. Set a WebUI password on first login
(qBittorrent shows a temporary one in `docker compose logs qbittorrent`).

qBittorrent runs as `PUID:PGID` from its `.env`. `PGID` must be the group
that owns `DOWNLOADS_DIR` (mounted read-write at the same path inside and
out) — a supplementary `group_add` is silently dropped by this image's
`s6-setuidgid`, so the media group has to be the primary GID. The
BitTorrent peer port
(`BT_PORT`, default 6881) is the one port published to the host — peer data
transfer, not a management UI.

## Monitoring

`monitoring/` covers the whole host and every Docker project. Grafana is the
only web face (same caddy + dns-sync front as the others → `grafana.<domain>`);
everything else talks only on the compose network.

```
Alloy ──metrics──▶ Prometheus ─┐
  │  (host/unix exporter,       ├─▶ Grafana ──alerts──▶ ntfy
  │   cAdvisor, nvidia GPU,     │
  │   media-exporter)           │
  └──logs────────▶ Loki ────────┘
     (every container + journald)
```

| Container | Job |
|---|---|
| `grafana` | dashboards + unified alerting (no separate Alertmanager) |
| `prometheus` | metrics store, 30-day retention, remote-write receiver |
| `loki` | log store, single-binary + filesystem, 14-day retention |
| `alloy` | the one collector — host metrics, container logs, journald |
| `cadvisor` | per-container CPU / memory / restarts / OOM |
| `nvidia-gpu-exporter` | GPU util / VRAM / temp / NVENC sessions |
| `smartctl-exporter` | disk SMART health, sectors, wear, temp (privileged, `/dev` ro) |
| `media-exporter` | qBittorrent transfers/torrents + Jellyfin playback (see below) |

Everything under `monitoring/grafana/provisioning/` and
`monitoring/grafana/dashboards/` is loaded on start: the two datasources, a
**Homelab Overview** dashboard, **Media Pipeline** (below), **Node Exporter
Full** (Grafana 1860), the `ntfy` contact point, and 21 alert rules — disk
full, RAM, CPU temp, GPU temp, scrape target down, container restart loop,
container/host OOM kill, systemd unit failed, SMART
health/bad-sectors/temp/wear, SSH brute-force (Loki), and the seven media
rules listed below.

### Media pipeline metrics

Everything above watches the host and the containers. `_media-exporter/` is a
small stdlib-only Python exporter that watches what those containers are
actually *doing*, and Alloy scrapes it as `job="media"`:

- **qBittorrent** — global and per-torrent transfer rates, torrent counts by
  state and by category, share ratio, peer/DHT counts, free space on the save
  path, and how long the oldest incomplete torrent has been outstanding.
- **Jellyfin** — active streams broken down by play method (the
  DirectPlay/Transcode split is the one that matters), how many streams the
  server is transcoding, summed stream bitrate, library item counts, and a row
  per session for a "now playing" table.

It reaches qBittorrent over the shared `downloads` network, where the WebUI
auth-subnet whitelist means **no credentials are needed**. Jellyfin does need
one: *Dashboard → Advanced → API Keys → +*, then put it in `monitoring/.env` as
`JELLYFIN_API_KEY` and `docker compose up -d media-exporter`. Leave it empty
and the exporter skips Jellyfin — the qBittorrent half works regardless, and
the Jellyfin alerts stay silent because their series never appear.

Per-torrent series are capped at `MAX_TORRENT_SERIES` (default 60), preferring
torrents that are erroring or downloading over idle seeders, so a large library
can't run away with the TSDB.

The **Media Pipeline** dashboard puts both halves on one page. The panel worth
knowing about is *"Transcodes vs. what the GPU is doing"*: it plots Jellyfin's
transcode count against `nvidia_smi_encoder_stats_session_count`. If Jellyfin
says it is transcoding and the NVENC line stays flat at zero, hardware
acceleration silently fell back to the CPU.

The seven media alert rules: qBittorrent API unreachable, qBittorrent
firewalled (no peer connectivity for 20m), downloads disk under 50 GiB,
downloads stalled for 2h, torrents in an error state, Jellyfin API unreachable,
and more than three simultaneous transcodes.

### Setup

`.env` needs the usual tailscale/Cloudflare block plus:

- `GRAFANA_ADMIN_PASSWORD` — initial `admin` password
- `NTFY_URL` — an unguessable ntfy topic, with templating so alerts render as
  real text instead of raw JSON:
  `https://ntfy.sh/<topic>?template=yes&title=%7B%7B.title%7D%7D&message=%7B%7B.message%7D%7D`
- `JELLYFIN_API_KEY` — optional, unlocks the Jellyfin metrics (see above)

The `media-exporter` service joins the two shared networks, so both must exist
first:

```sh
docker network create --subnet 172.28.0.0/16 downloads   # if not already there
docker network create media
```

```sh
cd monitoring
cp .env.example .env      # then edit
docker compose up -d
```

There is **no host node_exporter** — Alloy's unix exporter reads the host
through the `/rootfs`, `/var/log/journal` and `docker.sock` bind mounts.
`cadvisor` runs `privileged` (it needs raw cgroup/device access); everything
else is unprivileged.

Stack footprint is ~1 GB RAM. No memory limits are set — add `mem_limit:` per
service if the host gets tight (it also runs Jellyfin transcodes, ollama and
Sunshine).
