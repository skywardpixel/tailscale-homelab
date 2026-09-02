# tailscale-homelab

Docker Compose projects for self-hosted services, each fronted by its own
[Caddy](https://caddyserver.com/) + [Tailscale](https://tailscale.com/) node
so the web UI is reachable only over the tailnet, on HTTPS, with nothing
bound to a host port (bar the odd non-UI port like BitTorrent's).

| Project        | Image                              | Reachable at                              |
|----------------|------------------------------------|-------------------------------------------|
| `autobangumi`  | `ghcr.io/estrellaxd/auto_bangumi`  | `<host>.<tailnet>.ts.net` + custom domain |
| `jellyfin`     | `jellyfin/jellyfin`                | `<host>.<tailnet>.ts.net` + custom domain |
| `qbittorrent`  | `lscr.io/linuxserver/qbittorrent`  | `<host>.<tailnet>.ts.net` + custom domain |

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

Image versions are **pinned** in each `compose.yaml`
(`image: …:${SOMETHING_VERSION:-<pinned>}`) — not `latest` — so a rebuild or a
fresh host gets the exact stack that was last tested. `docker compose pull` on
a pinned tag still picks up base-OS security rebuilds (LinuxServer republishes
the `X.Y.Z` qBittorrent tag; that's why it's pinned to the short tag, not the
`…_v2.0.14-lsNNN` form).

[Renovate](https://docs.renovatebot.com/) (config in `renovate.json`) watches
the pinned tags — `compose.yaml` images and the two `Dockerfile`s — and opens
one PR per update with a link to the changelog. Nothing updates on its own.

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

qBittorrent runs `PUID:PGID` from its `.env` plus `MEDIA_GID` as a
supplementary group so it can manage files under `DOWNLOADS_DIR` (mounted
read-write at the same path inside and out). The BitTorrent peer port
(`BT_PORT`, default 6881) is the one port published to the host — peer data
transfer, not a management UI.
