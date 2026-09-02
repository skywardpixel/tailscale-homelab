# tailscale-homelab

Docker Compose projects for self-hosted services, each fronted by its own
[Caddy](https://caddyserver.com/) + [Tailscale](https://tailscale.com/) node
so the web UI is reachable only over the tailnet, on HTTPS, with nothing
bound to a host port (bar the odd non-UI port like BitTorrent's).

| Project        | Image                              | Reachable at                              |
|----------------|------------------------------------|-------------------------------------------|
| `animegakill`  | `ghcr.io/skywardpixel/animegakill` | no web UI — driven by `config.yaml`       |
| `autobangumi`  | `ghcr.io/estrellaxd/auto_bangumi`  | retired — replaced by `animegakill`       |
| `jellyfin`     | `jellyfin/jellyfin`                | `<host>.<tailnet>.ts.net` + custom domain |
| `qbittorrent`  | `lscr.io/linuxserver/qbittorrent`  | `<host>.<tailnet>.ts.net` + custom domain |
| `monitoring`   | Grafana + Prometheus + Loki + Alloy | `<host>.<tailnet>.ts.net` + custom domain |

Each project is a directory with a `compose.yaml`, a `Caddyfile`, and an
`.env.example`. Copy `.env.example` to `.env` (gitignored) and fill it in —
`docker compose` reads `.env` automatically. No secrets are committed.

`animegakill` is the one exception: it has no web UI, so it has no `Caddyfile`
and no `caddy`/`dns-sync` sidecars — just the app on the `downloads` network.

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
`CNAME` `${CUSTOM_DOMAIN}` → `${TS_HOSTNAME}.${TAILNET_NAME}.ts.net`**, so the
custom domain routes to this node over the tailnet without anyone pasting an
IP. Pointing at the MagicDNS name (not an `A` record) means it never needs
updating when the node's Tailscale IP changes. It's idempotent — only writes
when the record is missing or wrong — and exits.

### Prerequisites

- A tailnet with **HTTPS Certificates** enabled (Admin console → DNS).
- One Tailscale auth key **per node** (non-ephemeral). Node identity then
  persists in the `tailscale_state` volume across restarts.
- A Cloudflare API token with **Zone → DNS → Edit** (plus **Zone → Zone →
  Read**, which the "Edit zone DNS" template already includes) for the zone
  behind `${CUSTOM_DOMAIN}`. One token can cover multiple services in the same
  zone. Used for both the ACME DNS-01 challenge and the `dns-sync` service.

The custom-domain DNS record is created and kept current by the `dns-sync`
service — no manual record needed. It still only resolves for devices on the
tailnet (MagicDNS), which is the point.

## Bring up a project

```sh
cd <project>
cp .env.example .env      # then edit .env
docker compose up -d              # also runs dns-sync once (creates the CNAME)
docker compose logs -f caddy      # watch the tailnet join + cert issuance
```

`dns-sync` runs as part of `up` and exits; check it with
`docker compose logs dns-sync`, or re-run it on its own with
`docker compose run --rm dns-sync`.

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
AutoBangumi's downloader host is `qbittorrent:8080` (`ssl: false`).

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

## animegakill

A second, lighter take on the same job as AutoBangumi: watch anime RSS feeds,
hand new episodes to qBittorrent, rename the files in place so Jellyfin reads
them. The difference is that **every feed lives in `animegakill/config.yaml`**,
tracked in this repo, instead of in a web UI backed by a mutable database.

Source and image: [skywardpixel/AnimeGaKill](https://github.com/skywardpixel/AnimeGaKill).

It is deliberately smaller than the other projects here:

- **No web UI**, so no `Caddyfile`, no `caddy`, no `dns-sync`, and no
  Tailscale block in `.env`. `docker compose logs` is the whole interface.
- **No credentials needed.** It sits on the `downloads` network, which
  qBittorrent's WebUI auth-subnet whitelist bypasses, and it only logs in if
  the server actually returns a 403. `QB_PASS` stays empty.
- **No media mount and no PUID/PGID.** It never touches the files — it calls
  qBittorrent's API and writes one sqlite file — so it runs `read_only`, with
  `cap_drop: ALL`, as a non-root user.

```sh
cd animegakill
cp .env.example .env               # DOWNLOADS_DIR + TZ; the rest stays empty
cp config.example.yaml config.yaml # gitignored; add your feeds here

docker compose run --rm animegakill feeds   # what each entry parses/filters to
docker compose run --rm animegakill -n once # dry run: what a pass would do
docker compose up -d
```

### Editing feeds

`config.yaml` is the service. It is **gitignored** — a subscription list is
personal and this repo is public — so `config.example.yaml` is committed as the
template, the same way `.env.example` is. It carries no secrets either:
`${QB_PASS}`, `${MIKAN_TOKEN}` and `${DOWNLOADS_DIR}` are expanded from `.env`
at load time.

```sh
$EDITOR animegakill/config.yaml
docker compose run --rm animegakill feeds    # verify before applying
docker compose restart animegakill
```

After adding a show, seed it so the back catalogue is not re-downloaded on top
of episodes you already have:

```sh
docker compose run --rm animegakill mark-seen -f "<feed name>"
```

`feeds` prints one line per entry with the verdict — `+` would download,
`-` filtered by a rule (and which one), `?` unparsable — which is the fastest
way to catch a wrong `include:` or a season/offset mistake before it downloads
anything. `config.yaml` itself is validated on start; a typo fails the
container's healthcheck rather than being silently ignored.

Set `skip_backlog: true` (the default here) when adding a mid-season show so it
picks up from the next episode instead of queueing the whole season.

### Migrated from AutoBangumi

`autobangumi/` is retired (`docker compose down`) — its four subscriptions now
live in `animegakill/config.yaml`. Its volumes are untouched, so bringing it
back is one `docker compose up -d`.

Two things that bit during the migration, worth knowing if you ever run both
again:

- **Use a different qBittorrent category.** animegakill uses `AnimeGaKill`;
  AutoBangumi used `Bangumi`. The renamer selects torrents *by category*, so
  sharing one means each tool renames the other's downloads.
- **Seed state before the first real run.** Without `mark-seen`, a newly
  migrated feed looks entirely new and re-downloads the whole back catalogue on
  top of files you already have.

## Monitoring

`monitoring/` covers the whole host and every Docker project. Grafana is the
only web face (same caddy + dns-sync front as the others → `grafana.<domain>`);
everything else talks only on the compose network.

```
Alloy ──metrics──▶ Prometheus ─┐
  │  (host/unix exporter,       ├─▶ Grafana ──alerts──▶ ntfy
  │   cAdvisor, nvidia GPU)     │
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

Everything under `monitoring/grafana/provisioning/` and
`monitoring/grafana/dashboards/` is loaded on start: the two datasources, a
**Homelab Overview** dashboard + **Node Exporter Full** (Grafana 1860), the
`ntfy` contact point, and 14 alert rules — disk full, RAM, CPU temp, GPU temp,
scrape target down, container restart loop, container/host OOM kill, systemd
unit failed, SMART health/bad-sectors/temp/wear, and SSH brute-force (Loki).

### Setup

`.env` needs the usual tailscale/Cloudflare block plus:

- `GRAFANA_ADMIN_PASSWORD` — initial `admin` password
- `NTFY_URL` — an unguessable ntfy topic, with templating so alerts render as
  real text instead of raw JSON:
  `https://ntfy.sh/<topic>?template=yes&title=%7B%7B.title%7D%7D&message=%7B%7B.message%7D%7D`

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
