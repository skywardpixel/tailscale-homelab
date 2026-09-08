# Monitoring

[Back to overview](../README.md) · [Shared setup](../README.md#bring-up-a-project) · [Upgrades and rollback](../README.md#upgrading)

Run Compose commands from `monitoring/`. Complete the shared prerequisites
and the service-specific preparation below before starting the project.

This project covers the whole host and every Docker project. Grafana is the
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

Everything under [grafana/provisioning/](grafana/provisioning/) and
[grafana/dashboards/](grafana/dashboards/) is loaded on start: the two datasources, a
**Homelab Overview** dashboard, **Media Pipeline** (below), **Node Exporter
Full** (Grafana 1860), the `ntfy` contact point, and 21 alert rules — disk
full, RAM, CPU temp, GPU temp, scrape target down, container restart loop,
container/host OOM kill, systemd unit failed, SMART
health/bad-sectors/temp/wear, SSH brute-force (Loki), and the seven media
rules listed below.

## Media pipeline metrics

Everything above watches the host and the containers. [_media-exporter/](../_media-exporter/) is a
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
one: *Dashboard → Advanced → API Keys → +*, then put it in `.env` as
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

## Setup

`.env` needs the usual tailscale/Cloudflare block plus:

- `GRAFANA_ADMIN_PASSWORD` — initial `admin` password
- `NTFY_URL` — an unguessable ntfy topic, with templating so alerts render as
  real text instead of raw JSON:
  `https://ntfy.sh/<topic>?template=yes&title=%7B%7B.title%7D%7D&message=%7B%7B.message%7D%7D`
- `JELLYFIN_API_KEY` — optional, unlocks the Jellyfin metrics (see above)

The `media-exporter` service joins both `downloads` and `media`. Create them
using [shared Docker networks](../README.md#shared-docker-networks), and follow
[qBittorrent API setup](../qbittorrent/README.md#api-access) for its authentication
requirements.

```sh
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
