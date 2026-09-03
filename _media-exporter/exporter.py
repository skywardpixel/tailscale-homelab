#!/usr/bin/env python3
"""Prometheus exporter for the media pipeline: qBittorrent + Jellyfin.

The rest of the monitoring stack watches the host and the containers. This
watches what they are actually *doing* — what is downloading, what is seeding,
who is streaming and whether the GPU is transcoding for them.

Standard library only, so the image is just `python:alpine` with this file in
it. Metrics are collected on scrape and cached briefly (CACHE_SECONDS) so a
tight Prometheus interval can't hammer either API.
"""

import json
import os
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

QBIT_URL = os.environ.get("QBIT_URL", "http://qbittorrent:8080").rstrip("/")
QBIT_USERNAME = os.environ.get("QBIT_USERNAME", "")
QBIT_PASSWORD = os.environ.get("QBIT_PASSWORD", "")

JELLYFIN_URL = os.environ.get("JELLYFIN_URL", "http://jellyfin:8096").rstrip("/")
JELLYFIN_API_KEY = os.environ.get("JELLYFIN_API_KEY", "")

LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9101"))
TIMEOUT = float(os.environ.get("TIMEOUT_SECONDS", "10"))
CACHE_SECONDS = float(os.environ.get("CACHE_SECONDS", "10"))

# Per-torrent series are bounded by this. Torrents that are actually doing
# something (downloading, stalled, erroring) are kept first; idle seeders fill
# whatever is left. Prevents a 5000-torrent library from melting the TSDB.
MAX_TORRENT_SERIES = int(os.environ.get("MAX_TORRENT_SERIES", "60"))

USER_AGENT = "media-exporter/1.0"


def log(msg):
    print(f"[media-exporter] {msg}", file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# metric rendering
# --------------------------------------------------------------------------

_ESCAPES = str.maketrans({"\\": "\\\\", "\n": "\\n", '"': '\\"'})


class Metrics:
    """Accumulates samples and renders them in Prometheus text format.

    Samples are grouped by metric name so the HELP/TYPE header is emitted once
    per family, which is what the text format requires.
    """

    def __init__(self):
        self._families = {}   # name -> {"help":..., "type":..., "samples":[...]}
        self._order = []

    def add(self, name, value, labels=None, help=None, type="gauge"):
        fam = self._families.get(name)
        if fam is None:
            fam = {"help": help or name, "type": type, "samples": []}
            self._families[name] = fam
            self._order.append(name)
        fam["samples"].append((labels or {}, value))

    def set(self, name, value, labels=None):
        """Overwrite a family's samples — used to flip an `up` gauge that was
        registered optimistically before the collector knew the outcome."""
        fam = self._families[name]
        fam["samples"] = [(labels or {}, value)]

    def render(self):
        out = []
        for name in self._order:
            fam = self._families[name]
            out.append(f"# HELP {name} {fam['help']}")
            out.append(f"# TYPE {name} {fam['type']}")
            for labels, value in fam["samples"]:
                if labels:
                    pairs = ",".join(
                        f'{k}="{str(v).translate(_ESCAPES)}"'
                        for k, v in labels.items()
                    )
                    out.append(f"{name}{{{pairs}}} {_fmt(value)}")
                else:
                    out.append(f"{name} {_fmt(value)}")
        out.append("")
        return "\n".join(out)


def _fmt(v):
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, float):
        if v != v:
            return "NaN"
        if v == float("inf"):
            return "+Inf"
        if v == float("-inf"):
            return "-Inf"
        return repr(v)
    return str(v)


def _num(value, default=0):
    """qBittorrent hands back some numbers as strings (e.g. global_ratio)."""
    try:
        if value is None or value == "":
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


# --------------------------------------------------------------------------
# qBittorrent
# --------------------------------------------------------------------------

class QBittorrent:
    """qBittorrent WebUI API client.

    Auth is optional on purpose: this repo whitelists the `downloads` subnet in
    qBittorrent's WebUI settings, so an exporter on that network needs no
    credentials. Set QBIT_USERNAME/QBIT_PASSWORD if yours isn't whitelisted.
    """

    def __init__(self, base):
        self.base = base
        self.sid = None

    def _request(self, path, data=None, retry=True):
        url = f"{self.base}{path}"
        body = urllib.parse.urlencode(data).encode() if data else None
        req = urllib.request.Request(url, data=body)
        req.add_header("User-Agent", USER_AGENT)
        # qBittorrent rejects cross-origin-looking calls without a matching
        # Referer when the host header isn't what it expects.
        req.add_header("Referer", self.base)
        if self.sid:
            req.add_header("Cookie", f"SID={self.sid}")
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                return resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code in (401, 403) and retry and QBIT_USERNAME:
                self.login()
                return self._request(path, data, retry=False)
            raise

    def login(self):
        if not QBIT_USERNAME:
            return
        url = f"{self.base}/api/v2/auth/login"
        body = urllib.parse.urlencode(
            {"username": QBIT_USERNAME, "password": QBIT_PASSWORD}
        ).encode()
        req = urllib.request.Request(url, data=body)
        req.add_header("Referer", self.base)
        req.add_header("User-Agent", USER_AGENT)
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            if resp.read().decode().strip() != "Ok.":
                raise RuntimeError("qBittorrent rejected the credentials")
            for header in resp.headers.get_all("Set-Cookie") or []:
                if header.startswith("SID="):
                    self.sid = header.split(";", 1)[0][4:]
        if not self.sid:
            raise RuntimeError("qBittorrent login returned no SID cookie")

    def maindata(self):
        return json.loads(self._request("/api/v2/sync/maindata?rid=0"))


# States qBittorrent reports. Grouped so a dashboard can ask "how much is
# actively moving" without enumerating the raw enum every time.
DOWNLOADING_STATES = {
    "downloading", "metaDL", "forcedDL", "allocating", "checkingDL", "queuedDL",
}
SEEDING_STATES = {"uploading", "forcedUP", "stalledUP", "checkingUP", "queuedUP"}
STALLED_STATES = {"stalledDL"}
ERROR_STATES = {"error", "missingFiles", "unknown"}
PAUSED_STATES = {"pausedDL", "pausedUP", "stoppedDL", "stoppedUP"}


def collect_qbittorrent(m, client):
    started = time.monotonic()
    m.add("qbittorrent_up", 0,
          help="1 if the qBittorrent API answered this scrape")
    try:
        data = client.maindata()
    except Exception as e:
        log(f"qBittorrent scrape failed: {e}")
        m.set("qbittorrent_up", 0)
        return
    m.set("qbittorrent_up", 1)

    s = data.get("server_state", {})
    torrents = list(data.get("torrents", {}).values())

    m.add("qbittorrent_download_bytes_per_second", _num(s.get("dl_info_speed")),
          help="Current global download rate")
    m.add("qbittorrent_upload_bytes_per_second", _num(s.get("up_info_speed")),
          help="Current global upload rate")
    m.add("qbittorrent_download_rate_limit_bytes_per_second",
          _num(s.get("dl_rate_limit")),
          help="Configured global download cap (0 = unlimited)")
    m.add("qbittorrent_upload_rate_limit_bytes_per_second",
          _num(s.get("up_rate_limit")),
          help="Configured global upload cap (0 = unlimited)")
    m.add("qbittorrent_session_downloaded_bytes", _num(s.get("dl_info_data")),
          help="Bytes downloaded this qBittorrent session")
    m.add("qbittorrent_session_uploaded_bytes", _num(s.get("up_info_data")),
          help="Bytes uploaded this qBittorrent session")
    m.add("qbittorrent_downloaded_bytes_total", _num(s.get("alltime_dl")),
          help="Bytes downloaded all-time", type="counter")
    m.add("qbittorrent_uploaded_bytes_total", _num(s.get("alltime_ul")),
          help="Bytes uploaded all-time", type="counter")
    m.add("qbittorrent_global_ratio", _num(s.get("global_ratio")),
          help="All-time share ratio reported by qBittorrent")
    m.add("qbittorrent_dht_nodes", _num(s.get("dht_nodes")),
          help="DHT nodes currently known")
    m.add("qbittorrent_peer_connections", _num(s.get("total_peer_connections")),
          help="Open peer connections across all torrents")
    m.add("qbittorrent_free_space_bytes", _num(s.get("free_space_on_disk")),
          help="Free space on the default save path's filesystem")
    m.add("qbittorrent_wasted_bytes", _num(s.get("total_wasted_session")),
          help="Bytes discarded this session (failed hash checks, duplicates)")
    m.add("qbittorrent_alt_speed_limits_active",
          1 if s.get("use_alt_speed_limits") else 0,
          help="1 while the alternate (slow) speed limits are in force")
    m.add("qbittorrent_connected",
          1 if s.get("connection_status") == "connected" else 0,
          help="1 when qBittorrent reports a working BitTorrent connection")

    # ---- aggregates over the torrent list ----
    by_state, by_category, by_tracker_status = {}, {}, {"ok": 0, "error": 0}
    total_size = incomplete_bytes = 0.0
    now = time.time()
    oldest_incomplete_age = 0.0
    active_downloads = 0

    for t in torrents:
        state = t.get("state", "unknown")
        by_state[state] = by_state.get(state, 0) + 1
        cat = t.get("category") or "(none)"
        by_category[cat] = by_category.get(cat, 0) + 1
        total_size += _num(t.get("size"))
        left = _num(t.get("amount_left"))
        incomplete_bytes += left
        if t.get("has_tracker_error"):
            by_tracker_status["error"] += 1
        else:
            by_tracker_status["ok"] += 1
        if left > 0:
            added = _num(t.get("added_on"))
            if added > 0:
                oldest_incomplete_age = max(oldest_incomplete_age, now - added)
        if state in DOWNLOADING_STATES:
            active_downloads += 1

    for state, count in sorted(by_state.items()):
        m.add("qbittorrent_torrents", count, {"state": state},
              help="Torrents by qBittorrent state")
    for cat, count in sorted(by_category.items()):
        m.add("qbittorrent_torrents_by_category", count, {"category": cat},
              help="Torrents by category")

    grouped = {
        "downloading": sum(c for st, c in by_state.items() if st in DOWNLOADING_STATES),
        "seeding": sum(c for st, c in by_state.items() if st in SEEDING_STATES),
        "stalled": sum(c for st, c in by_state.items() if st in STALLED_STATES),
        "paused": sum(c for st, c in by_state.items() if st in PAUSED_STATES),
        "error": sum(c for st, c in by_state.items() if st in ERROR_STATES),
    }
    for group, count in grouped.items():
        m.add("qbittorrent_torrents_grouped", count, {"group": group},
              help="Torrents rolled up into coarse states")

    m.add("qbittorrent_torrents_tracked", len(torrents),
          help="Torrents known to qBittorrent")
    m.add("qbittorrent_torrents_size_bytes", total_size,
          help="Summed size of every torrent in the client")
    m.add("qbittorrent_incomplete_bytes", incomplete_bytes,
          help="Bytes still to fetch across all torrents")
    m.add("qbittorrent_oldest_incomplete_age_seconds", oldest_incomplete_age,
          help="Age of the longest-outstanding incomplete torrent")
    m.add("qbittorrent_torrents_tracker_error", by_tracker_status["error"],
          help="Torrents whose tracker is reporting an error")

    # ---- per-torrent series, capped ----
    def priority(t):
        state = t.get("state", "")
        if state in ERROR_STATES:
            return 0
        if state in DOWNLOADING_STATES or state in STALLED_STATES:
            return 1
        if _num(t.get("upspeed")) > 0:
            return 2
        return 3

    interesting = sorted(
        torrents,
        key=lambda t: (priority(t), -_num(t.get("added_on"))),
    )[:MAX_TORRENT_SERIES]

    for t in interesting:
        labels = {
            "name": (t.get("name") or "")[:120],
            "category": t.get("category") or "(none)",
            "state": t.get("state", "unknown"),
        }
        m.add("qbittorrent_torrent_progress_ratio", _num(t.get("progress")), labels,
              help="Per-torrent completion, 0-1")
        m.add("qbittorrent_torrent_download_bytes_per_second",
              _num(t.get("dlspeed")), labels, help="Per-torrent download rate")
        m.add("qbittorrent_torrent_upload_bytes_per_second",
              _num(t.get("upspeed")), labels, help="Per-torrent upload rate")
        m.add("qbittorrent_torrent_size_bytes", _num(t.get("size")), labels,
              help="Per-torrent total size")
        m.add("qbittorrent_torrent_ratio", _num(t.get("ratio")), labels,
              help="Per-torrent share ratio")
        # qBittorrent uses 8640000 (100 days) as its "unknown ETA" sentinel.
        eta = _num(t.get("eta"))
        if 0 < eta < 8640000:
            m.add("qbittorrent_torrent_eta_seconds", eta, labels,
                  help="Per-torrent estimated seconds to completion")
        m.add("qbittorrent_torrent_seeds", _num(t.get("num_seeds")), labels,
              help="Seeds currently connected for this torrent")
        m.add("qbittorrent_torrent_peers", _num(t.get("num_leechs")), labels,
              help="Leechers currently connected for this torrent")

    m.add("qbittorrent_scrape_duration_seconds", time.monotonic() - started,
          help="Time taken to collect qBittorrent metrics")
    log(f"qBittorrent ok: {len(torrents)} torrents, {active_downloads} downloading")


# --------------------------------------------------------------------------
# Jellyfin
# --------------------------------------------------------------------------

def jellyfin_get(path):
    url = f"{JELLYFIN_URL}{path}"
    req = urllib.request.Request(url)
    req.add_header("User-Agent", USER_AGENT)
    # Jellyfin accepts either; sending both keeps this working across the
    # 10.8 -> 10.11 header changes without caring which one is current.
    req.add_header("Authorization", f'MediaBrowser Token="{JELLYFIN_API_KEY}"')
    req.add_header("X-Emby-Token", JELLYFIN_API_KEY)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def collect_jellyfin(m):
    if not JELLYFIN_API_KEY:
        return
    started = time.monotonic()
    m.add("jellyfin_up", 0, help="1 if the Jellyfin API answered this scrape")
    try:
        sessions = jellyfin_get("/Sessions")
        counts = jellyfin_get("/Items/Counts")
    except Exception as e:
        log(f"Jellyfin scrape failed: {e}")
        return
    m.set("jellyfin_up", 1)

    for key, value in sorted(counts.items()):
        # MovieCount -> movie, SeriesCount -> series, ...
        kind = key[:-5] if key.endswith("Count") else key
        m.add("jellyfin_items", _num(value), {"type": kind.lower()},
              help="Items in the Jellyfin libraries by type")

    playing = [s for s in sessions if s.get("NowPlayingItem")]
    by_method, by_type = {}, {}
    total_bitrate = 0.0
    transcoding = 0

    for s in playing:
        item = s.get("NowPlayingItem") or {}
        play_state = s.get("PlayState") or {}
        method = play_state.get("PlayMethod") or "Unknown"
        by_method[method] = by_method.get(method, 0) + 1
        media_type = item.get("MediaType") or item.get("Type") or "Unknown"
        by_type[media_type] = by_type.get(media_type, 0) + 1
        if method == "Transcode":
            transcoding += 1
        total_bitrate += _num((s.get("TranscodingInfo") or {}).get("Bitrate")) \
            or _num(item.get("Bitrate"))

        # One series per active stream — bounded by concurrent viewers, so this
        # is safe cardinality and makes a "who is watching what" table trivial.
        m.add("jellyfin_session_info", 1, {
            "user": s.get("UserName") or "unknown",
            "client": s.get("Client") or "unknown",
            "device": s.get("DeviceName") or "unknown",
            "item": (item.get("Name") or "unknown")[:120],
            "series": (item.get("SeriesName") or "")[:120],
            "play_method": method,
            "media_type": media_type,
        }, help="One series per active playback session")

        position = _num(play_state.get("PositionTicks"))
        runtime = _num(item.get("RunTimeTicks"))
        if runtime > 0:
            m.add("jellyfin_session_progress_ratio", position / runtime, {
                "user": s.get("UserName") or "unknown",
                "item": (item.get("Name") or "unknown")[:120],
            }, help="How far through the item each session is, 0-1")

    for method in ("DirectPlay", "DirectStream", "Transcode", "Unknown"):
        m.add("jellyfin_streams", by_method.get(method, 0),
              {"play_method": method},
              help="Active playback sessions by play method")
    for media_type, count in sorted(by_type.items()):
        m.add("jellyfin_streams_by_type", count, {"media_type": media_type},
              help="Active playback sessions by media type")

    m.add("jellyfin_active_streams", len(playing),
          help="Sessions currently playing something")
    m.add("jellyfin_transcoding_streams", transcoding,
          help="Sessions the server is transcoding for")
    m.add("jellyfin_stream_bitrate_bits_per_second", total_bitrate,
          help="Summed bitrate of every active stream")
    m.add("jellyfin_sessions_tracked", len(sessions),
          help="Client sessions Jellyfin is tracking, playing or idle")
    m.add("jellyfin_scrape_duration_seconds", time.monotonic() - started,
          help="Time taken to collect Jellyfin metrics")
    log(f"Jellyfin ok: {len(playing)} streaming, {transcoding} transcoding")


# --------------------------------------------------------------------------
# http
# --------------------------------------------------------------------------

_cache = {"body": "", "at": 0.0}
_lock = threading.Lock()
_qbit = QBittorrent(QBIT_URL)


def build_metrics():
    m = Metrics()
    started = time.monotonic()
    collect_qbittorrent(m, _qbit)
    collect_jellyfin(m)
    m.add("media_exporter_scrape_duration_seconds", time.monotonic() - started,
          help="Total time to build this response")
    m.add("media_exporter_build_info", 1, {"version": "1.0"},
          help="Exporter build information")
    return m.render()


def metrics_body():
    with _lock:
        now = time.monotonic()
        if now - _cache["at"] < CACHE_SECONDS and _cache["body"]:
            return _cache["body"]
        _cache["body"] = build_metrics()
        _cache["at"] = now
        return _cache["body"]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path.startswith("/metrics"):
            body = metrics_body().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path in ("/", "/health"):
            body = b"media-exporter: try /metrics\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def log_message(self, *args):
        pass  # access logs would drown the useful lines


class Server(ThreadingHTTPServer):
    daemon_threads = True
    address_family = socket.AF_INET
    allow_reuse_address = True


def main():
    log(f"qBittorrent: {QBIT_URL} (auth: {'yes' if QBIT_USERNAME else 'subnet whitelist'})")
    log(f"Jellyfin:    {JELLYFIN_URL} ({'enabled' if JELLYFIN_API_KEY else 'no API key, skipped'})")
    if QBIT_USERNAME:
        try:
            _qbit.login()
        except Exception as e:
            log(f"initial qBittorrent login failed, will retry on scrape: {e}")
    log(f"listening on :{LISTEN_PORT}/metrics")
    Server(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
