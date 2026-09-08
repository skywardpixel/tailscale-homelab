# AutoBangumi

[Back to overview](../README.md) · [Shared setup](../README.md#bring-up-a-project) · [Upgrades and rollback](../README.md#upgrading)

Run Compose commands from `autobangumi/`. Complete the shared prerequisites
and the service-specific preparation below before starting the project.

## Connect to qBittorrent

Complete [qBittorrent setup](../qbittorrent/README.md) first, including its
`downloads` network and WebUI password. Both projects attach to that network,
so API calls stay inside Docker without a round-trip through the tailnet.

Set AutoBangumi's downloader host to `qbittorrent:8080` with `ssl: false`.
The [qBittorrent API access rules](../qbittorrent/README.md#api-access) allow
requests from this network without credentials.

## Existing volumes

[compose.yaml](compose.yaml) uses the external volumes `AutoBangumi_config`
and `AutoBangumi_data` from the previous installation. On a fresh host, create
them before starting AutoBangumi:

```sh
docker volume create AutoBangumi_config
docker volume create AutoBangumi_data
```

When recovering an existing installation, restore those volumes from
[backup](../backup/README.md#restoring) before starting the service.
