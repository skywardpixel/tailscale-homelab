# tailscale-homelab

Docker Compose projects for self-hosted services, each fronted by its own
[Caddy](https://caddyserver.com/) + [Tailscale](https://tailscale.com/) node
so the service is reachable only over the tailnet, on HTTPS, with no host
ports published.

| Project       | Image                                    | Reachable at                              |
|---------------|------------------------------------------|-------------------------------------------|
| `autobangumi` | `ghcr.io/estrellaxd/auto_bangumi`        | `<host>.<tailnet>.ts.net` + custom domain |
| `jellyfin`    | `jellyfin/jellyfin`                      | `<host>.<tailnet>.ts.net` + custom domain |

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

### Prerequisites

- A tailnet with **HTTPS Certificates** enabled (Admin console → DNS).
- One Tailscale auth key **per node** (non-ephemeral). Node identity then
  persists in the `tailscale_state` volume across restarts.
- A Cloudflare API token scoped to **Zone → DNS → Edit** for the zone behind
  `${CUSTOM_DOMAIN}`. One token can cover multiple services in the same zone.
- For each custom domain: a **DNS-only** (grey-cloud) `A` record pointing at
  that node's Tailscale IPv4 (`docker compose exec caddy tailscale ip -4`).

## Bring up a project

```sh
cd <project>
cp .env.example .env      # then edit .env
docker compose up -d
docker compose logs -f caddy      # watch the tailnet join + cert issuance
```

Update / restart / tear down:

```sh
docker compose pull && docker compose up -d --build   # update images
docker compose restart caddy                          # reload Caddyfile changes
docker compose down                                   # stop (volumes kept)
```

## Jellyfin migration (from a native install)

`jellyfin/migrate.sh` moves a native (Debian package) Jellyfin into this
project. It keeps the native in-container paths (`/var/lib/jellyfin`,
`/etc/jellyfin`, `/var/cache/jellyfin`) and runs as the native `jellyfin`
uid:gid so migrated files and absolute paths in the database stay valid.
Media is bind-mounted read-only at the same path inside and out.

Config lives in `jellyfin/.env`:

| Var                              | What                                                        |
|----------------------------------|------------------------------------------------------------|
| `MEDIA_DIR`                      | host media path, mounted read-only at the same path        |
| `JELLYFIN_UID` / `JELLYFIN_GID`  | user to run as — `getent passwd jellyfin` on the old host   |
| `MEDIA_GID`                      | group that owns the media files (`stat -c %g <file>`)       |
| `JELLYFIN_VERSION`               | image tag                                                   |

Steps (all need `sudo`):

1. **NVIDIA container toolkit** (only if you want GPU transcoding):

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

   For an Intel/AMD iGPU instead, drop the `deploy:` block from
   `jellyfin/compose.yaml`, pass through `/dev/dri`, and add the host's
   `render` group to `group_add`.

2. Fill in `jellyfin/.env`, then:

   ```sh
   cd jellyfin
   sudo ./migrate.sh          # stops + disables jellyfin.service, copies data
   docker compose up -d
   ```

3. In the Jellyfin web UI:
   - **Dashboard → Playback**: set/confirm hardware acceleration (NVENC),
     then force a transcode and check `nvidia-smi` shows an `ffmpeg` process.
   - **Dashboard → Networking**: add the `caddy` container to *Known proxies*
     (`docker compose exec caddy hostname -i`) so client IPs are logged.

The native install's data is left in place — remove it once you're satisfied.
