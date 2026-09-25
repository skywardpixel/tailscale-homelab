# Hermes Agent

[Back to overview](../README.md)

An always-on personal assistant using the official
[`nousresearch/hermes-agent`](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
image, pinned to `v2026.9.7`. The gateway and dashboard run in one container.
Caddy serves the dashboard on HTTPS over Tailscale; no host ports are published.
The gateway API listens only on loopback inside the Hermes container.

## First setup

Run these commands from `hermes/` on the Docker host:

```sh
cp .env.example .env
```

Edit `.env`: fill in the Tailscale and Cloudflare settings, a unique dashboard
password, and two separately generated `openssl rand -hex 32` values for
`HERMES_SESSION_SECRET` and `HERMES_API_KEY`. Keep these values in this
gitignored file. Leave `TS_IPV4` blank until Caddy has joined the tailnet.

This project reserves `172.29.91.0/24` for its private Compose network, with
Caddy at `172.29.91.3`. If that overlaps another Docker, LAN, or VPN network,
change the subnet and Caddy address in `compose.yaml` and use the new Caddy
address in the trusted-proxies command below.

Initialize the persistent data volume and choose your model provider:

```sh
docker compose pull hermes
docker compose run --rm -e HERMES_DASHBOARD=0 hermes setup
```

Enter provider credentials directly in the wizard. They are saved in
`/opt/data/.env` inside the volume. Messaging integrations are optional;
the internal API keeps the gateway available for dashboard use. No local
model server is installed by this project.

Set the terminal workspace and proxy settings. Replace the sample URL with
the HTTPS custom domain you entered in `.env`:

```sh
docker compose run --rm -e HERMES_DASHBOARD=0 hermes config set terminal.backend local
docker compose run --rm -e HERMES_DASHBOARD=0 hermes config set terminal.cwd /opt/data/workspace
docker compose run --rm -e HERMES_DASHBOARD=0 hermes config set dashboard.public_url https://hermes.example.com
docker compose run --rm -e HERMES_DASHBOARD=0 hermes config set dashboard.trusted_proxies '["172.29.91.3"]'
```

Here `local` means commands execute inside the Hermes container. The workspace
is a dedicated directory within the persistent data volume. Agent commands
can also access Hermes's state and credentials; this is not a separate sandbox
per task. The container has no Docker socket mount, and its only host mount is the
read-only `skills/` directory (see [Repo-managed skills](#repo-managed-skills)).

Start Hermes and its proxy first:

```sh
docker compose up -d --build hermes caddy
docker compose logs -f hermes caddy
```

Find this new Caddy node's IPv4 in the Tailscale admin console and put it in
`TS_IPV4` in `.env`. Then start DNS sync:

```sh
docker compose up -d --build
docker compose logs dns-sync
```

Unlike the other projects, blank `TS_IPV4` is accepted during Compose parsing
so first setup can proceed. The shared DNS sync script still rejects a missing
or invalid address before making changes.

Open `https://<CUSTOM_DOMAIN>` while connected to the tailnet and sign in with
`HERMES_USERNAME` and `HERMES_PASSWORD`. The tailnet hostname is also proxied,
but use the custom domain as the canonical dashboard URL. Confirm a chat
receives a model response and ask Hermes to create a small file in
`/opt/data/workspace`; check it remains after a container recreation.

## Operation

```sh
docker compose logs -f hermes
docker compose exec hermes hermes gateway status
docker compose exec hermes hermes config set terminal.cwd /opt/data/workspace
docker compose restart hermes
```

Use `docker compose exec hermes hermes setup` to revise provider or messaging
configuration, then restart Hermes. After initial setup, use `exec` for
configuration rather than launching additional containers against the same
volume. Never run two gateways against one data volume.

The image's s6 supervisor manages the gateway and dashboard and drops them
to its non-root runtime user after initializing storage. Keep its entrypoint
and default user configuration. The service is limited to 4 GiB RAM and two
CPUs; adjust those limits if browser-heavy work requires more.

Upgrades follow the repository's pinned-image workflow. Change the image tag,
back up state, then run `docker compose pull hermes` and
`docker compose up -d hermes`. Update the container image rather than running
`hermes update` inside it.

## Repo-managed skills

`skills/` is mounted read-only at `/opt/homelab-skills` and loaded through
Hermes's `skills.external_dirs`. Edits made here, or pulled with git, take
effect without copying. The agent cannot modify these skills. Skills it
creates itself still go to `/opt/data/skills` in the volume. Enable this once:

```sh
docker compose exec hermes hermes config set skills.external_dirs '["/opt/homelab-skills"]'
docker compose up -d hermes
```

### Fabric

`skills/fabric/` lets Hermes run [Fabric](../fabric/README.md) patterns over
the tailnet. Hermes reaches Fabric's custom domain through the Docker host's
Tailscale connection. Add the URL and key to `/opt/data/.env`, using values
from `../fabric/.env`, then restart Hermes:

```sh
FABRIC_URL=https://fabric.example.com
FABRIC_API_KEY=<FABRIC_API_KEY>
```

The skill lists both variables under `required_environment_variables`, so
Hermes passes them only to the commands that skill runs. They are stripped
from other terminal commands.

## Backup and restore

`hermes_data` holds credentials, configuration, conversations, memory, skills,
scheduled jobs, and workspace files. `hermes_tailscale_state` holds the proxy's
node identity. Both are included by the existing backup service's default
named-volume policy. The project's `.env` is captured with the repository.

Scheduled backups copy live files. For a consistent Hermes snapshot, stop
the `hermes` service, run the backup, and restart it when the backup finishes.
Restore the whole data volume while Hermes is stopped, following the
[backup instructions](../backup/README.md). Preserve `.env` and Tailscale state
as well. `docker compose down` keeps volumes; `down -v` deletes them.
