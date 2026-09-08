# tailscale-homelab

Docker Compose projects for self-hosted services, each fronted by its own
[Caddy](https://caddyserver.com/) + [Tailscale](https://tailscale.com/) node
so the web UI is reachable only over the tailnet, on HTTPS, with nothing
bound to a host port (bar the odd non-UI port like BitTorrent's).

| Project          | Image                               | Reachable at                              |
|------------------|-------------------------------------|-------------------------------------------|
| [audiobookshelf](audiobookshelf/README.md) | `ghcr.io/advplyr/audiobookshelf`    | `<host>.<tailnet>.ts.net` + custom domain |
| [autobangumi](autobangumi/README.md)    | `ghcr.io/estrellaxd/auto_bangumi`   | `<host>.<tailnet>.ts.net` + custom domain |
| [jellyfin](jellyfin/README.md)       | `jellyfin/jellyfin`                 | `<host>.<tailnet>.ts.net` + custom domain |
| [qbittorrent](qbittorrent/README.md)    | `lscr.io/linuxserver/qbittorrent`   | `<host>.<tailnet>.ts.net` + custom domain |
| [monitoring](monitoring/README.md)     | Grafana + Prometheus + Loki + Alloy | `<host>.<tailnet>.ts.net` + custom domain |
| [backup](backup/README.md)         | `restic/restic`                     | no web UI — self-scheduling restic backup |

Each project has a `compose.yaml` and an `.env.example`; web-facing
projects also have a `Caddyfile`. Copy `.env.example` to `.env` (gitignored) and fill it in —
`docker compose` reads `.env` automatically. No secrets are committed.

## How the Caddy + Tailscale front works

`_caddy-tailscale/` holds one shared `Dockerfile`: Caddy built with
[`xcaddy`](https://github.com/caddyserver/xcaddy) plus two plugins —
[`tailscale/caddy-tailscale`](https://github.com/tailscale/caddy-tailscale)
and [`caddy-dns/cloudflare`](https://github.com/caddy-dns/cloudflare). Every
web-facing project builds its `caddy` service from `../_caddy-tailscale` and tags the
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

## Shared Docker networks

Create the networks needed by the projects you plan to run, once per host:

| Network | Used by | Create with |
|---|---|---|
| `downloads` | qBittorrent, AutoBangumi, monitoring | `docker network create --subnet 172.28.0.0/16 downloads` |
| `media` | Jellyfin, monitoring | `docker network create media` |

The `downloads` subnet also controls qBittorrent's API authentication bypass;
see [qBittorrent setup](qbittorrent/README.md#api-access).

## Bring up a project

Read the project's README first for storage and service-specific prerequisites.
The following commands apply to web-facing projects; the
[backup service](backup/README.md) has its own setup and scheduler.

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
`compose.yaml` images and shared `Dockerfile`s — and opens one PR per update
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

## Backups and host setup

See [backup and restore](backup/README.md) for volume coverage, scheduling,
consistency requirements, and recovery instructions.
