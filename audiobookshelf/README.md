# Audiobookshelf

[Back to overview](../README.md) · [Shared setup](../README.md#bring-up-a-project) · [Upgrades and rollback](../README.md#upgrading)

Run Compose commands from `audiobookshelf/`. Complete the shared prerequisites
and the service-specific preparation below before starting the project.

One host path, mounted read-only:

- `AUDIOBOOKS_DIR` → `/audiobooks`, **read-only**. Audiobookshelf keeps cover
  art and its scan results in the `metadata` volume, so it never needs to
  write into the library. Drop the `:ro` if you want the web uploader, or
  *Settings → Item Metadata Utils → "Store metadata with item"*, which moves
  those files out of `/metadata/items` and into the library folders.
- `PODCASTS_DIR` — **removed.** Audiobookshelf writes podcast episodes into
  its podcast folder, which would be the only writable host path here. With no
  podcast library in use, the mount was dead weight and has been dropped.

Create the audiobooks directory before the first `up` — Docker auto-creates a
missing bind-mount source as `root:root`, which you then cannot write to
without `sudo`:

```sh
sudo mkdir -p /mnt/downloads/audiobooks
sudo chown "$USER":"$USER" /mnt/downloads/audiobooks
```

## Why it runs as the image's default user

It didn't always. An earlier version ran the app as a dedicated `audiobookshelf`
uid, with a one-shot `init` service to chown the named volumes first — because
a freshly created volume is `root:root 0755` and non-root Audiobookshelf dies
on it with `EACCES: mkdir '/metadata/logs'`.

That whole apparatus existed for one reason: container root writing podcast
episodes onto `/mnt/downloads`, which is ext4 mounted without `nosuid`. Since
no podcast library is in use, that mount is gone, and with it the only writable
host path — the library itself is `:ro`, and everything else the app writes
lands in its own Docker volumes. So the `user:` override and the `init` service
were both removed as machinery guarding a risk that no longer exists.

**Bring it back if either of these changes:** you add a podcast library, or you
make `AUDIOBOOKS_DIR` read-write for the web uploader. Both reintroduce a
writable host path. The removed setup is in the git history — see the commit
that added it, and the one that took it out.

Add `/audiobooks` as the library folder in the first-run wizard.

Two Docker-managed volumes, and the split matters for restores:

- `config` — the SQLite database: users, libraries, and **listening
  progress**. The one thing here that genuinely cannot be recreated.
- `metadata` — cover art, cached transcodes, and Audiobookshelf's own internal
  backups. Rebuildable, but a rescan re-matches everything from scratch, so
  it's left in the restic backup. If it ever grows past what you want to
  snapshot nightly, add `audiobookshelf_metadata` to `EXCLUDE_VOLUMES`.

No GPU block, unlike Jellyfin: the image ships `ffmpeg` and audio transcoding
is cheap on CPU.

Nothing extra is needed in the Caddyfile — Caddy passes Audiobookshelf's
socket.io connection through as a normal WebSocket upgrade, and puts no limit
on request bodies, so large uploads work if you make the library writable.

**On a phone**, note there is no official Audiobookshelf iOS app — the
official app is Android-only. On iOS the usable clients are third-party:
SoundLeaf (offline downloads free in its base tier) and Plappa (downloads
behind a one-time purchase). Whichever you use, it reaches `${CUSTOM_DOMAIN}`
only while the Tailscale app is connected, since the address is tailnet-only. Downloading books to the device for
offline playback is the way around that, not a public listener.


Copy books into the host library directory, then scan the library in
Audiobookshelf. See [backup and restore](../backup/README.md#restoring) for
volume recovery.
