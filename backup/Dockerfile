# restic plus a small scheduler. The repository it writes is ordinary restic
# format — nothing here is needed to read it back, which is the point: a
# restore must not depend on Docker being healthy.
FROM restic/restic:0.18.1

# busybox crond, flock, nice and ionice all ship in the base image, so the
# scheduler needs no extra packages.
COPY backup.sh run-backup.sh healthcheck.sh entrypoint.sh /usr/local/bin/

# Runs as root: it reads /var/lib/docker/volumes (root-only) and writes the
# repository onto a root-owned mount.
#
# Unhealthy when no backup has succeeded within STALE_AFTER_HOURS. start-period
# is generous because a first run on an empty repository uploads everything.
HEALTHCHECK --interval=15m --timeout=30s --start-period=30m --retries=2 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
