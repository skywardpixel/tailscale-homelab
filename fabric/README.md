# Fabric

[Back to overview](../README.md) · [Shared setup](../README.md#bring-up-a-project) · [Upgrades and rollback](../README.md#upgrading)

[Fabric](https://github.com/danielmiessler/fabric) runs its crowdsourced
prompt "patterns" against an LLM provider. This project runs it as a REST
server (`fabric --serve`) using the maintainer-published `kayvan/fabric`
image, pinned to `v1.4.480`. Caddy serves the API on HTTPS over Tailscale; no
host ports are published. No local model server is installed. Fabric calls
whichever hosted provider you configure.

The server spends money on that provider, so it requires an API key in
addition to being reachable only on the tailnet. Every request must send
`X-API-Key: $FABRIC_API_KEY`.

## First setup

Run these commands from `fabric/` on the Docker host:

```sh
cp .env.example .env
```

Generate a new non-ephemeral auth key for this node in the Tailscale admin
console (Settings → Keys) and put it in `TS_AUTHKEY`. Don't reuse another
project's key: Fabric's Caddy is a separate tailnet node.

Edit `.env`: fill in the rest of the Tailscale and Cloudflare settings and set
`FABRIC_API_KEY` to a value from `openssl rand -hex 32`. Leave `TS_IPV4` blank
until Caddy has joined the tailnet.

Initialize the config volume, choose a provider and default model, and
download the patterns:

```sh
docker compose pull fabric
docker compose run --rm fabric --setup
```

Enter provider credentials directly in the wizard. They are saved in
`/home/appuser/.config/fabric/.env` inside the volume. Run setup before the
first `up`: the server exits at startup if that file is missing, and the
container restart-loops until it exists.

Start Fabric and its proxy first:

```sh
docker compose up -d --build fabric caddy
docker compose logs -f fabric caddy
```

Find this new Caddy node's IPv4 in the Tailscale admin console and put it in
`TS_IPV4` in `.env`. Then start DNS sync:

```sh
docker compose up -d --build
docker compose logs dns-sync
```

As with Hermes, a blank `TS_IPV4` is accepted during Compose parsing so first
setup can proceed. The shared DNS sync script still rejects a missing or
invalid address before making changes.

## Using it

From any tailnet machine:

```sh
curl -H "X-API-Key: $FABRIC_API_KEY" https://fabric.example.com/patterns/names

curl -N https://fabric.example.com/chat \
  -H "X-API-Key: $FABRIC_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"prompts":[{"userInput":"<text>","vendor":"<vendor>","model":"<model>","patternName":"summarize"}]}'
```

`/chat` streams its answer as server-sent events. Caddy passes the stream
through without buffering. The interactive API reference is at
`/swagger/index.html`.

Hermes and other tailnet clients can call the same endpoints. Give each one
the API key through its own secret store, not in a committed file.

Fabric's web UI (`web/` in the upstream repo) is a separate app and is not
included in this image or this project.

## Operation

```sh
docker compose logs -f fabric
docker compose run --rm fabric --updatepatterns   # refresh upstream patterns
docker compose run --rm fabric --setup            # change provider or model
docker compose restart fabric                     # pick up config changes
```

The image runs as its non-root `appuser`. A fresh named volume inherits that
user's ownership from the image, so no init step is needed. The service is
limited to 1 GiB RAM and one CPU. It only relays requests to the provider.

Upgrades follow the repository's pinned-image workflow: change the tag, then
`docker compose pull fabric` and `docker compose up -d fabric`.

## Backup and restore

`fabric_config` holds provider credentials, patterns (including any custom
ones), contexts and sessions. `fabric_tailscale_state` holds the proxy's node
identity. Both are included by the backup service's default named-volume
policy. Downloaded patterns can be fetched again; custom patterns and
credentials cannot. Restore the volume while Fabric is stopped, following the
[backup instructions](../backup/README.md).
