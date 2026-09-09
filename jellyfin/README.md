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

## Anime metadata and TVDB v23 fix

The Anime library uses TheTVDB as its sole online metadata and image provider
for series, seasons, and episodes. Its metadata language is Japanese (`ja`,
country `JP`); embedded images and screen grabs remain episode-image fallbacks.
These settings live in the config volume at `/config/root/default/Anime/options.xml`.
Oshi no Ko and Frieren use `absolute` episode display order because their files
use continuous numbering under `Season 1`. Re:Zero uses aired order with files
such as `Season 4/... S04E16.mp4`. SPY×FAMILY also uses aired order: its 12 files
were moved from `Season 1/S01E38–50` to `Season 3/S03E01–13`, subtracting 37 from
the episode number. Episode 48 (now S03E11) was already absent. TVDB's absolute
order includes the movie before season 3, so it does not match the release
group's continuous TV-episode numbering. The rename map and prior user state
are saved in `/config/backups/tvdb-v23-20260909/`.

On 2026-09-09, TheTVDB 23.0.0.0 needed a local fix on Jellyfin 12.0: episodes
without a TVDB episode ID were skipped even when their series had a valid ID.
The log misleadingly reported `not checked as series ID is 0`.
[Upstream issue #266](https://github.com/jellyfin/jellyfin-plugin-tvdb/issues/266)
and [fix #267](https://github.com/jellyfin/jellyfin-plugin-tvdb/pull/267) describe it.

The installed DLL was built from official tag `v23`, commit
`511add6a925675e07206c8090425140cc5be3a2c`, with
[this patch](patches/tvdb-v23-episode-series-id.patch). It changes the guard to
read `SeriesProviderIds` and corrects the series ID in the failure log.
The release build resolved Jellyfin packages to `12.0.0` and Tvdb.Sdk to `4.7.10`.
The build used the official .NET 10 SDK image with digest
`sha256:4ea6fe75dd36706bb6d8c3c293d4c4315840f5d76ea28ac97def77e3ec487fa5`.

Installed file: `/config/plugins/TheTVDB_23.0.0.0/Jellyfin.Plugin.Tvdb.dll`.
SHA-256: `99ec9a0e536ed16a790e2dada9a1c0ac3a215413033f84d730030971170f1705`.
The original DLL, plugin manifest, and stopped-server database backup are in
`/config/backups/tvdb-v23-20260909/`. To roll back the plugin, stop Jellyfin,
restore the original DLL to its plugin directory, then start Jellyfin.
The library settings backup is `options.xml.before-tvdb-only-20260909` beside
`options.xml`.

Validation: the same Re:Zero S04E16 refresh failed before the patch and fetched
TVDB episode `11714318` (title, synopsis, air date, and artwork) afterward.
A full Anime refresh completed for 12 series, 12 seasons, and 199 episodes;
all 199 episodes have TVDB IDs after correcting the three series' episode orders.

Plugin auto-updates remain enabled. Replace this local build with an official
release containing #267 when available; reinstalling unpatched v23 restores
the bug.
