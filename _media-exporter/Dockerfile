# Prometheus exporter for the media pipeline (qBittorrent + Jellyfin).
# Standard library only, so there is nothing to install — the image is the
# upstream Python base plus one file. Built by monitoring/compose.yaml and
# tagged services/media-exporter:local. Renovate watches this pinned tag.
FROM python:3.13-alpine

ENV PYTHONUNBUFFERED=1

COPY exporter.py /usr/local/bin/exporter.py

# Unprivileged: it only makes outbound HTTP calls and serves /metrics.
USER nobody

EXPOSE 9101

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request,os,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:'+os.environ.get('LISTEN_PORT','9101')+'/health', timeout=4).status==200 else 1)"]

ENTRYPOINT ["python", "/usr/local/bin/exporter.py"]
