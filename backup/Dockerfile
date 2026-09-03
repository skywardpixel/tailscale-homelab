# restic plus one script. The repository it writes is ordinary restic format —
# nothing here is needed to read it back, which is the point: a restore must
# not depend on Docker being healthy.
FROM restic/restic:0.18.1

COPY backup.sh /usr/local/bin/backup.sh

# Runs as root: it reads /var/lib/docker/volumes (root-only) and writes the
# repository onto a root-owned mount.
ENTRYPOINT ["/usr/local/bin/backup.sh"]
