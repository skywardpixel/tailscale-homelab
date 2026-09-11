# Jellyfin

[Back to overview](../README.md) · [Shared setup](../README.md#bring-up-a-project) · [Upgrades and rollback](../README.md#upgrading)

Run Compose commands from `jellyfin/`. Complete the shared prerequisites
and the service-specific preparation below before starting the project.

Create the `media` network as described in [shared Docker networks](../README.md#shared-docker-networks).


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
[compose.yaml](compose.yaml), add `devices: [/dev/dri:/dev/dri]`, and add a
`group_add` for the host's `render` group.

After first-run setup, in the Jellyfin web UI:

- **Dashboard → Playback**: enable NVENC hardware acceleration, then force a
  transcode and check `nvidia-smi` on the host shows an `ffmpeg` process.
- **Dashboard → Networking**: add the `caddy` container to *Known proxies*
  (`docker compose exec caddy hostname -i`) so client IPs are logged.


See [monitoring](../monitoring/README.md#media-pipeline-metrics) for playback
metrics and [backup and restore](../backup/README.md#restoring) for volume recovery.

## Anime metadata and TheTVDB

The Anime library uses TheTVDB as its sole online metadata and image provider
for series, seasons, and episodes. Both Anime and TV Shows use Simplified Chinese
metadata (`zh-cn`, country `CN`), matching the server default; embedded images
and screen grabs remain episode-image fallbacks for Anime.
These settings live in the config volume at `/config/root/default/Anime/options.xml`.
TV Shows settings live at `/config/root/default/TV Shows/options.xml`.
Existing text metadata was refreshed on 2026-09-11. The prior library settings
and full metadata for 157 items are saved in
`/config/backups/chinese-metadata-20260911/`; existing artwork was preserved.
Oshi no Ko and Frieren use `absolute` episode display order because their files
use continuous numbering under `Season 1`. Re:Zero uses aired order with files
such as `Season 4/... S04E16.mp4`. SPY×FAMILY also uses aired order: its 12 files
were moved from `Season 1/S01E38–50` to `Season 3/S03E01–13`, subtracting 37 from
the episode number. Episode 48 (now S03E11) was already absent. TVDB's absolute
order includes the movie before season 3, so it does not match the release
group's continuous TV-episode numbering. The rename map and prior user state
are saved in `/config/backups/tvdb-v23-20260909/`.

Use the official [TheTVDB v24 release](https://github.com/jellyfin/jellyfin-plugin-tvdb/releases/tag/v24)
or later. Version 24 includes [fix #267](https://github.com/jellyfin/jellyfin-plugin-tvdb/pull/267),
which checks the series TVDB ID when an episode ID is missing or zero. This
resolves [issue #266](https://github.com/jellyfin/jellyfin-plugin-tvdb/issues/266),
where v23 skipped episodes despite a valid series ID and logged
`not checked as series ID is 0`.

The local v23 DLL patch and custom build are no longer needed. Plugin
auto-updates remain enabled; use the official release instead of restoring
the patched v23 build. The historical library settings backup remains at
`options.xml.before-tvdb-only-20260909` beside `options.xml`.
