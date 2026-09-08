# qBittorrent

[Back to overview](../README.md) · [Shared setup](../README.md#bring-up-a-project) · [Upgrades and rollback](../README.md#upgrading)

Run Compose commands from `qbittorrent/`. Complete the shared prerequisites
and the service-specific preparation below before starting the project.

## API access

Create the `downloads` network before starting the project; see
[shared Docker networks](../README.md#shared-docker-networks).
[AutoBangumi](../autobangumi/README.md) and the
[monitoring exporter](../monitoring/README.md#media-pipeline-metrics) use this
network to call qBittorrent's API directly.

[init.d/10-webui-whitelist.sh](init.d/10-webui-whitelist.sh) (run by the LinuxServer
image before qBittorrent starts) adds that subnet to qBittorrent's
*WebUI → auth subnet whitelist*, so clients on the `downloads` network reach
the API without credentials. Everything else — including the Caddy front, on
a different subnet — still has to log in. Set a WebUI password on first login
(qBittorrent shows a temporary one in `docker compose logs qbittorrent`).

## Storage and permissions

qBittorrent runs as `PUID:PGID` from its `.env`. `PGID` must be the group
that owns `DOWNLOADS_DIR` (mounted read-write at the same path inside and
out) — a supplementary `group_add` is silently dropped by this image's
`s6-setuidgid`, so the media group has to be the primary GID. The
BitTorrent peer port
(`BT_PORT`, default 6881) is the one port published to the host — peer data
transfer, not a management UI.
