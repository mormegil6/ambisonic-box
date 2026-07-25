#!/usr/bin/env python3
# hoa360 telemetry: containerised collector + alerter + dashboard server.
#
# Runs as the `telemetry` compose service. Every INTERVAL seconds it:
#   - reads container health + the player access log via the mounted docker socket,
#   - reads stream liveness from the shared dash-output volume and earshot's /stat,
#   - reads CPU temp / disk from optional host mounts (degrades to null if absent),
#   - writes stats.json (private dashboard) + public-stats.json (curated, for the
#     stream page) + a viewers.csv history,
#   - fires Telegram on the RISING edge of a *sustained* problem (debounced) and on
#     recovery. Telegram is optional (skipped unless BOT_TOKEN/CHAT_ID are set).
#
# A tiny threaded HTTP server serves the dashboard on TEL_PORT. stdlib only + the
# docker CLI (installed in the image; the socket is mounted read-write, because
# on-demand idling starts and stops the loop-source container).
import json, os, re, subprocess, time, ipaddress, threading
import http.server, socketserver, urllib.parse, urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta
from pathlib import Path

HOST     = os.environ.get("TEL_HOST", "example-host")
def _own_project():
    """The compose project this telemetry container actually belongs to, read
    from its own labels (hostname == container id). The env var is only a
    fallback: it cannot see a `docker compose -p <name>` override, and a
    hardcoded value once broke loop control under any renamed project."""
    try:
        import socket
        out = sh(f"docker inspect {socket.gethostname()} "
                 "--format '{{index .Config.Labels \"com.docker.compose.project\"}}'").strip()
        if out and out != "<no value>":
            return out
    except Exception:
        pass
    return os.environ.get("COMPOSE_PROJECT_NAME", "hoa360")

PROJECT  = _own_project()
DATA     = Path(os.environ.get("TEL_DATA", "/data"))          # persisted volume + web root
DASH     = Path(os.environ.get("TEL_DASH", "/dash"))          # shared dash-output (ro)
THERMAL  = os.environ.get("TEL_THERMAL", "/sys/class/thermal/thermal_zone0/temp")  # container sees host sysfs
DISKPATH = os.environ.get("TEL_DISK", "/host/root")           # host / mounted ro (optional)
EARSHOT  = os.environ.get("TEL_EARSHOT", "http://earshot/stat")
FFMPEG   = os.environ.get("FFMPEG_FLAGS", "")                 # to report resolution/bitrate
PORT     = int(os.environ.get("TEL_PORT", "8090"))
INTERVAL = int(os.environ.get("TEL_INTERVAL", "60"))
BOT      = os.environ.get("BOT_TOKEN", "").strip()
CHAT     = os.environ.get("CHAT_ID", "").strip()

VIEWER_WINDOW = 90; ENCODER_MIN = 0.90; SEG_STALE_S = 15
TEMP_CRIT_C = 100; DISK_FULL_PCT = 90; DEBOUNCE = 2

# On-demand source: idle the loop when nobody is watching, let a visitor restart it.
# RFC 6598 shared address space, which Tailscale hands out. Python's is_private
# returns False for it, so without this an operator watching over the VPN is
# counted as public audience and inflates the figure shown to real visitors.
CGNAT = ipaddress.ip_network("100.64.0.0/10")

SOURCE_SVC   = os.environ.get("TEL_SOURCE_SVC", "loop-source")
IDLE_STOP_MIN = int(os.environ.get("TEL_IDLE_STOP_MIN", "10"))   # 0 disables idling
START_GRACE_S = int(os.environ.get("TEL_START_GRACE_S", "300"))  # never idle just after a start
PUBDIR = Path(os.environ.get("TEL_PUB", "/pub"))   # shared with hoast-player (public)
STATS = DATA/"stats.json"; PUB = PUBDIR/"status.json"
CSV   = DATA/"viewers.csv"; STATE = DATA/"alert_state.json"


def run(cmd, t=12):
    """(ok, stdout). ok is False when the command could not be run at all or
    exited non-zero. Callers that act on the OUTPUT must not confuse that with
    "ran fine, said nothing": a docker probe that times out reads as an empty log,
    an empty log reads as nobody watching, and nobody watching stops the stream."""
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=t)
        return p.returncode == 0, p.stdout
    except Exception:
        return False, ""

def sh(cmd, t=12):
    """Output only, for probes where empty and failed mean the same thing."""
    return run(cmd, t)[1]

def now_iso():
    return datetime.now().astimezone().isoformat(timespec="seconds")

def docker_ps():
    out = sh(f'docker ps --filter "label=com.docker.compose.project={PROJECT}" --format "{{{{json .}}}}"')
    rows = []
    for line in out.splitlines():
        try:
            rows.append(json.loads(line))
        except Exception:
            pass
    return rows

def svc_label(row):
    for kv in (row.get("Labels", "") or "").split(","):
        if kv.startswith("com.docker.compose.service="):
            return kv.split("=", 1)[1]
    return row.get("Names", "")

def services(ps):
    rows = []
    for r in ps:
        # compose-managed long-lived containers ONLY: compose bakes the
        # service label into the IMAGE, so a stray `docker run` from e.g. the
        # earshot image shows up wearing service=earshot (seen live as a
        # doubled pill when a mock guest pusher ran from that image). The
        # oneoff=False label exists only on real `up`-managed containers;
        # same bug family as the arbiter's source_container filter.
        if "com.docker.compose.oneoff=False" not in (r.get("Labels", "") or ""):
            continue
        name = svc_label(r)
        if name in ("telemetry", "loop-source", "shaka"):   # self + non-core live path
            continue
        state, status = r.get("State", ""), r.get("Status", "")
        health = ("healthy" if "(healthy)" in status else
                  "unhealthy" if "(unhealthy)" in status else
                  "starting" if "starting" in status else "")
        rows.append({"name": name, "state": state, "health": health,
                     "healthy": state == "running" and health not in ("unhealthy", "starting")})
    return rows

def container_named(ps, service):
    for r in ps:
        if svc_label(r) == service:
            return r.get("Names", "")
    return ""

def temp_c():
    try:
        return round(int(Path(THERMAL).read_text().strip()) / 1000)
    except Exception:
        return None

def disk_pct():
    m = re.search(r"\s(\d+)%\s", sh(f"df -P {DISKPATH}"))
    return int(m.group(1)) if m else None

def mem_pct():
    """Host memory in use. /proc/meminfo inside the container is the host's, so
    this needs no mount. Based on MemAvailable rather than MemFree: page cache is
    reclaimable, and MemFree alone reads as ~100% used on any warm machine."""
    try:
        info = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            k, _, v = line.partition(":")
            if v.strip():
                info[k] = int(v.split()[0])      # kB
        total, avail = info.get("MemTotal"), info.get("MemAvailable")
        if not total or avail is None:
            return None
        return round((total - avail) * 100 / total)
    except Exception:
        return None

def uptime_s():
    try:
        return int(float(Path("/host/uptime").read_text().split()[0]))
    except Exception:
        try:
            return int(float(Path("/proc/uptime").read_text().split()[0]))
        except Exception:
            return None

def load1():
    try:
        return float(Path("/proc/loadavg").read_text().split()[0])
    except Exception:
        return None

def segment_age():
    """Age of the freshest segment of the STALEST track.

    Globbing chunk-stream*.webm alone is wrong whenever the video is
    stream-copied: ffmpeg's dash muxer writes H.264 as fragmented MP4
    (chunk-stream0-*.m4s) and only the Opus audio stays WebM, so a *.webm glob
    watches the audio and calls a stalled video encoder live. Taking the max
    across representations means either track going quiet marks the stream down.
    """
    newest = {}
    now = time.time()
    try:
        for pat in ("chunk-stream*.webm", "chunk-stream*.m4s", "chunk-stream*.mp4"):
            for p in DASH.glob(pat):
                m = re.match(r"chunk-stream(\d+)-", p.name)
                if not m:
                    continue
                age = now - p.stat().st_mtime
                rep = m.group(1)
                if rep not in newest or age < newest[rep]:
                    newest[rep] = age
    except Exception:
        return None
    return round(max(newest.values())) if newest else None


def stream_state():
    x = sh(f"curl -s --max-time 5 {EARSHOT}")
    publishing = "<publishing/>" in x
    m = re.search(r"<nclients>(\d+)</nclients>", x)
    nclients = int(m.group(1)) if m else 0
    seg_age = segment_age()
    live = publishing and seg_age is not None and seg_age < SEG_STALE_S
    return {"publishing": publishing, "nclients": nclients, "segment_age_s": seg_age, "live": live}

_enc_prev = [0.0, None]     # (wall clock, ffmpeg media time) of the previous poll

def encoder(ps, publishing):
    """Encoder progress, reported two ways.

    `speed` is ffmpeg's own figure, which is a CUMULATIVE average of pts over
    wall clock since process start. After an hour at 1.0x, a collapse to 0.3x
    needs ten more minutes to drag that average under ENCODER_MIN, and a milder
    0.85x collapse never gets there at all. That is the exact shape of thermal
    throttling, the failure this host is known for, and nothing else catches it:
    a throttled encoder still writes segments inside SEG_STALE_S, so
    stream_stalled stays quiet too.

    So `behind` is decided on `speed_now`: media time written divided by wall
    clock elapsed between two consecutive polls. `speed` is kept because the
    dashboard shows it and the lifetime average is still worth seeing.
    """
    if not publishing:
        _enc_prev[1] = None          # a restart must not be differenced across
        return {"speed": None, "speed_now": None, "behind": False}
    c = container_named(ps, "earshot")
    # tail -c rather than grep over the whole file: nginx-no-ssl.conf opens this
    # log with 2>> and never truncates it, so it reaches tens of MB in a
    # streaming day and was being read end to end every INTERVAL seconds. ffmpeg
    # separates progress updates with \r, so the last few KB always hold several.
    out = sh(f'docker exec {c} sh -c "tail -c 4096 /tmp/nginx_rtmp_ffmpeg_log 2>/dev/null"') if c else ""
    sps = re.findall(r"speed=\s*([0-9.]+)x", out)
    sp = float(sps[-1]) if sps else None
    ts = re.findall(r"time=(\d+):(\d\d):(\d\d(?:\.\d+)?)", out)
    media = (int(ts[-1][0]) * 3600 + int(ts[-1][1]) * 60 + float(ts[-1][2])) if ts else None
    rate, now = None, time.time()
    if media is not None:
        # Media time going backwards means a new ffmpeg process appended to the
        # same log, so the pair straddling the restart is meaningless. Skip one
        # poll rather than report a nonsense rate.
        if _enc_prev[1] is not None and media > _enc_prev[1] and now > _enc_prev[0]:
            rate = round((media - _enc_prev[1]) / (now - _enc_prev[0]), 2)
        _enc_prev[0], _enc_prev[1] = now, media
    return {"speed": sp, "speed_now": rate,
            "behind": rate is not None and rate < ENCODER_MIN}

def viewers(ps):
    c = container_named(ps, "hoast-player")
    out = sh(f"docker logs {c} --since {VIEWER_WINDOW}s 2>&1") if c else ""
    ips, any_ips, countries = set(), set(), {}
    for line in out.splitlines():
        if "/dash/" not in line or "[error]" in line or "[warn]" in line:
            continue
        parts = line.split(" ", 2)
        if len(parts) < 2:
            continue
        ip, cc = parts[0], parts[1]
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            continue
        any_ips.add(ip)     # counted before the public filter: see "any" below
        if addr.is_private or addr.is_loopback or addr.is_link_local or addr in CGNAT:
            continue
        if ip not in ips:
            ips.add(ip)
            if cc and cc not in ("--", "-", "XX"):
                countries[cc] = countries.get(cc, 0) + 1
    top = dict(sorted(countries.items(), key=lambda kv: -kv[1])[:6])
    # "now" is the audience figure the panels report, so it stays public-only.
    # "any" additionally counts LAN and VPN clients and is what the idle timer
    # reads: someone watching over Tailscale is still watching, and stopping the
    # stream under them because their address is private would be wrong.
    return {"now": len(ips), "any": len(any_ips),
            "window_s": VIEWER_WINDOW, "countries": top}

_start_lock = threading.Lock()
_last_start = [0.0]      # epoch of the last start we issued, for the idle grace period
_last_stop  = [0.0]      # epoch of the last stop; a stop supersedes an in-flight start
_idle_cycles = [0]
_src_cache = [0.0, False]   # (checked_at, running) for live_probe
_live_since = [None]        # epoch the stream last became live, for readiness

# A player pinned to a 30 s live delay cannot start on a timeline shorter than
# that: dash.js throws "Cannot read properties of null (reading 'range')" and
# never recovers. Measured on the box, a cold start reaches fresh segments at
# t+6 s but only plays once ~35 s of history exists (first frame t+43 s). So
# liveness is not readiness, and the player must not initialise until this.
READY_S = int(os.environ.get("TEL_READY_S", "35"))

# Reachability probes, both optional and env-gated so the code stays generic
# and deployments opt in (the box does; see its override). Neither needs a
# credential: cloudflared already serves /ready + /metrics on localhost, and
# the R2 check is an anonymous HEAD on a public object.
TUNNEL_METRICS_URL = os.environ.get("TUNNEL_METRICS_URL", "").rstrip("/")
VOD_PROBE_URL = os.environ.get("VOD_PROBE_URL", "")


def timeline_depth():
    """Seconds of media the manifest actually advertises, summed over its
    SegmentTimeline. This, not wall-clock uptime, is the quantity a player pinned
    to a live delay needs, and unlike wall-clock tracking it survives a telemetry
    restart instead of gating an already-running stream for no reason. Gates on
    the shortest track, since the player needs both audio and video."""
    try:
        mpds = sorted(DASH.glob("*.mpd"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not mpds:
            return None
        root = ET.parse(mpds[0]).getroot()
        best = None
        for st in root.iter():
            if not st.tag.endswith("SegmentTemplate"):
                continue
            ts = float(st.get("timescale") or 1) or 1.0
            total = 0.0
            for tl in st:
                if not tl.tag.endswith("SegmentTimeline"):
                    continue
                for seg in tl:
                    if seg.tag.endswith("S"):
                        total += float(seg.get("d") or 0) * (int(seg.get("r") or 0) + 1)
            if total:
                sec = total / ts
                best = sec if best is None else min(best, sec)
        return best
    except Exception:
        return None


def _note_live(is_live):
    if not is_live:
        _live_since[0] = None
    elif _live_since[0] is None:
        _live_since[0] = time.time()
    return _live_since[0]


def source_container(running_only=False):
    """Name of the loop-source container. Must look at stopped ones too: once the
    idle timer stops it, `docker ps` alone can no longer find it to start again.

    oneoff=False is load-bearing: `docker compose run ... loop-source` containers
    (the pipeline test's pusher, the guest test's pusher) carry the same service
    label, and without the filter a "stop the loop" during a guest handover
    matched the guest's own pusher and killed the publisher it was admitting.
    """
    flag = "" if running_only else "-a "
    out = sh(f'docker ps {flag}--filter "label=com.docker.compose.project={PROJECT}" '
             f'--filter "label=com.docker.compose.service={SOURCE_SVC}" '
             f'--filter "label=com.docker.compose.oneoff=False" --format "{{{{.Names}}}}"')
    lines = [l for l in out.strip().splitlines() if l.strip()]
    return lines[0] if lines else ""


def source_start():
    """Start the loop source. Idempotent by design: that is what makes it safe to
    expose publicly, since the worst a flood achieves is the stream running, which
    is the normal state anyway. Stopping stays private."""
    with _start_lock:
        # never start the demo loop under a guest: the shared MPD tolerates
        # exactly one writer, and the guest holds the slot until it is free.
        # _start_lock also serialises this whole check-then-start against the
        # guest handover (which stops the loop under the same lock), so the
        # two can only run one-after-the-other, never interleaved.
        with _guest_lock:
            guest_busy = _guest["state"] != "free"
        if guest_busy:
            return {"ok": False, "state": "guest_active",
                    "error": "a guest session holds the stream"}
        # coalesce a burst of start clicks, but ONLY while that start is still
        # in flight: a stop issued after it (a guest handover) supersedes it,
        # and coalescing then reports "starting" while nothing is starting -
        # which silently swallowed the resume after an operator kill
        if time.time() - _last_start[0] < 15 and _last_start[0] > _last_stop[0]:
            return {"ok": True, "state": "starting"}
        if stream_state()["publishing"]:
            return {"ok": True, "state": "already_publishing"}
        name = source_container()
        if not name:
            return {"ok": False, "state": "no_source",
                    "error": f"no {SOURCE_SVC} container in project {PROJECT}"}
        _last_start[0] = time.time()
        _idle_cycles[0] = 0
        sh(f"docker start {name}", t=30)
        print(f"source started ({name})", flush=True)
        return {"ok": True, "state": "starting"}


def source_stop(reason="manual", kill_after_s=None):
    """kill_after_s bounds docker's SIGTERM grace (-t). The guest handover
    passes a small value because it answers a held RTMP callback with a hard
    ~10 s patience; everywhere else the default (10 s) is fine."""
    name = source_container(running_only=True)
    if not name:
        return {"ok": True, "state": "already_stopped"}
    t_opt = f"-t {int(kill_after_s)} " if kill_after_s else ""
    sh(f"docker stop {t_opt}{name}", t=(int(kill_after_s) + 4) if kill_after_s else 40)
    _last_stop[0] = time.time()      # invalidates any in-flight start coalesce
    print(f"source stopped ({name}, {reason})", flush=True)
    return {"ok": True, "state": "stopped", "reason": reason}


def live_probe():
    """Cheap liveness, safe to poll every couple of seconds while a visitor waits
    for a cold start. Segment freshness only: no docker calls, no curl, just a
    stat of the dash directory, because the 60 s collect cycle is far too slow to
    drive a 30 s progress indicator."""
    seg_age = segment_age()
    # source_running distinguishes "idle, press start" from "running but broken",
    # and is the one docker call here, cached so a room full of waiting browsers
    # polling every few seconds cannot turn into a docker ps storm.
    now = time.time()
    if now - _src_cache[0] > 5:
        _src_cache[0], _src_cache[1] = now, bool(source_container(running_only=True))
    live = seg_age is not None and seg_age < SEG_STALE_S
    since = _note_live(live)
    depth = timeline_depth()
    if depth is None:                       # no SegmentTimeline: fall back to wall clock
        depth = (now - since) if since else 0
    # Ceil, not round, and derived from the same number as `ready`: rounding them
    # independently let the countdown reach 0 while ready was still false, so the
    # page said "0 seconds to go" and then sat there.
    remaining = max(0.0, READY_S - depth)
    ready = live and remaining <= 0
    # Which manifest to play, as a web path. Fixed per deployment in practice
    # (earshot writes ${DASH_NAME}.mpd whoever publishes), but reporting it here
    # is what frees the player page from a baked-in stream name.
    mpd = None
    try:
        mpds = sorted(DASH.glob("*.mpd"), key=lambda p: p.stat().st_mtime, reverse=True)
        if mpds:
            mpd = "/dash/" + mpds[0].name
    except Exception:
        pass
    return {"live": live,
            "ready": ready,                          # safe to initialise a player
            "timeline_s": round(depth),
            # The manifest grows one audio segment at a time, so this decreases in
            # ~5 s jumps. The page interpolates between polls; a raw display of
            # this value looks frozen for five seconds at a stretch.
            "ready_in_s": (0 if ready else int(-(-remaining // 1))) if live else None,
            "segment_age_s": seg_age,
            "source_running": _src_cache[1],
            "on_demand": IDLE_STOP_MIN > 0,
            "starting": now - _last_start[0] < 120,
            "mpd": mpd,
            **({"endpoint": ep} if (ep := guest_public()) else {})}


def idle_state(**set_):
    """Read, and optionally update, the persisted idle bookkeeping.

    Persisted rather than held in memory because the counter used to live in a
    module global: every telemetry restart silently restarted the countdown, so
    a few redeploys could keep the box encoding indefinitely with nobody
    watching, and the operator had no way to see how far along the timer was.
    """
    try:
        st = json.loads(STATE.read_text())
    except Exception:
        st = {}
    if set_:
        for k, v in set_.items():
            st["_" + k] = v
        try:
            STATE.write_text(json.dumps(st))
        except Exception:
            pass
    return st.get("_last_viewer"), st.get("_idle_accum", 0.0)


def auto_idle(strm, watchers):
    """Stop the source after IDLE_STOP_MIN with nobody watching. Long hysteresis
    on purpose: a short timer plus a 30 s cold start would flap as viewers come
    and go, and each cycle costs every waiting visitor that startup wait.

    The decision runs on accumulated confirmed-idle seconds rather than wall
    clock, so a failed probe neither counts as idleness nor resets progress.
    last_viewer is tracked separately, purely so the dashboard can say how long
    it has been since anyone watched.
    """
    now = time.time()
    if watchers is not None and watchers > 0:
        idle_state(last_viewer=now, idle_accum=0.0)
        return
    if _guest["state"] != "free":
        # the publisher is a guest, not the loop; "stop the source" would be a
        # no-op on an already-stopped container, but the idle bookkeeping would
        # still churn and log for nothing. Guests are never idled out: their
        # test needs no audience, and the cap bounds the session anyway.
        return
    if IDLE_STOP_MIN <= 0 or not strm["publishing"]:
        return
    if watchers is None:
        # The viewer probe failed, so "nobody is watching" is unproven. Freeze the
        # counter rather than counting the silence as idleness: stopping the source
        # costs every visitor a 35-43 s cold start, and it would happen with no
        # alert, since stream_stalled needs publishing to be true and we would
        # have just made it false ourselves. Uncertainty must never stop the
        # stream. Not reset either, so a flapping probe cannot hold the box in a
        # permanent encode.
        return
    if now - _last_start[0] < START_GRACE_S:
        idle_state(idle_accum=0.0)
        return
    _, accum = idle_state()
    accum += INTERVAL
    if accum >= IDLE_STOP_MIN * 60:
        idle_state(idle_accum=0.0)
        source_stop("idle")
    else:
        idle_state(idle_accum=accum)


# --------------------------------------------------------------------------
# Guest test endpoint arbiter. rtmp-ingest's `guest` application sends its
# on_publish / on_publish_done / on_update callbacks here (proxied through
# ingest's http block so the hostname resolves per request). This is the only
# authority on who may publish: one guest at a time, the demo loop paused for
# the duration, a reconnect grace after a disconnect, and an absolute session
# cap enforced by answering an on_update with a non-2xx (nginx-rtmp then drops
# the publisher). No keys, no queue, first come first served, by design.
#
# These routes are reachable on TEL_PORT: host-side that is localhost/VPN
# only, but INSIDE the compose network every sibling container can reach it
# unauthenticated (that is how ingest's proxy calls arrive). Like /api/stop,
# they are trusted surface; the trust boundary is the compose network plus
# whatever the operator binds 8090 to, and the public player proxies only
# /api/live and /api/start, never these.
# Master switch, OFF by default: most deployments are a single private
# publisher and should never expose a keyless application. Everything below
# no-ops when disabled, and the status surfaces omit the endpoint entirely.
GUEST_ENABLED = os.environ.get("GUEST_ENABLED", "0") == "1"
GUEST_GRACE_S = int(os.environ.get("GUEST_GRACE_S", "120"))   # reconnect window
GUEST_MAX_S   = int(os.environ.get("GUEST_MAX_S", "10800"))   # absolute cap, ±update interval
# After a session is ENDED by the cap or the operator kill (not a natural
# stop), guest publishes are refused for this long. Without it, an encoder
# with auto-reconnect re-claims the freed slot in seconds, which makes the cap
# a 3 h duty cycle instead of a limit and the kill button a two-second blip.
# 300 s outlasts OBS's default auto-reconnect budget (25 tries x 10 s).
GUEST_COOLDOWN_S = int(os.environ.get("GUEST_COOLDOWN_S", "300"))
INGEST_STAT   = os.environ.get("TEL_INGEST", "http://rtmp-ingest:8080/stat")
# Max hold on the on_publish callback while the loop unwinds. nginx-rtmp's
# netcall gives up at ~10 s (not configurable), and the docker stop before the
# wait is itself bounded to ~3.5 s, so the sum must stay safely under that.
HANDOVER_S    = 4
GSTATE  = DATA/"guest_state.json"
GUESTCSV = DATA/"guest_sessions.csv"
# Abuse reports (the player's report button). Same redaction regime as the
# session log: rows persist as statistics, IP columns expire.
REPORTCSV = DATA/"guest_reports.csv"
REPORT_IP_MAX = 3            # accepted reports per reporter IP...
REPORT_IP_WINDOW_S = 1800    # ...per this window
REPORT_COOLDOWN_S = 900      # one alert per session per this window
# A stalled guest transcode (wrong audio layout, most likely stereo/mono
# OBS) is ended automatically this long after the handover if no playable
# segment has appeared. Deliberately NO publish cooldown afterwards: the
# commonest cause is an innocent misconfiguration the pusher should be able
# to fix and retry immediately.
GUEST_STALL_S = 45

_guest_lock = threading.Lock()
_guest = {"state": "free", "name": None, "addr": None, "start": None,
          "last_seen": None, "grace_started": None, "kill": False,
          "terminating": None, "cooldown_until": None,
          "reports": 0, "last_report_alert": None,
          "last_end": None, "last_end_reason": None}
_reporters = {}              # reporter ip -> [accepted-report epochs]
_stall_timer = [None]
_guest_timer = [None]      # the pending grace-expiry threading.Timer
_resume_flag = [False]     # a resume attempt is owed (retried from guest_tick)
_pub_cache = [None]        # last status.json dict, for out-of-cycle endpoint updates


def _guest_sanitize(name):
    return (re.sub(r"[^A-Za-z0-9_-]", "", name or "")[:32]) or "guest"


def _guest_save():
    try:
        GSTATE.write_text(json.dumps(_guest))
    except Exception:
        pass


# The public notice says connection details are retained for 30 days. The
# session log follows the same split the viewer stats always used (counts and
# countries persist, identifiers do not): rows are kept indefinitely for
# statistics, but the IP column is REDACTED once it ages past the window. The
# country, resolved at write time and kept, is the aggregate-level residue,
# exactly like viewers.csv's country codes. Container stdout logs rotate by
# size, not by days; that residual is a known item for the final wording.
GUEST_RETENTION_S = int(os.environ.get("GUEST_RETENTION_DAYS", "30")) * 86400
# IP bans (dashboard "End + ban"). Clamped to the retention window on
# purpose: expiry and IP redaction are ONE event, so a ban outliving the
# address that defines it would be incoherent.
BANSCSV = DATA/"guest_bans.csv"
GUEST_BAN_DAYS = min(int(os.environ.get("GUEST_BAN_DAYS", "30")),
                     GUEST_RETENTION_S // 86400)

# --- offline IP -> country, for the session statistics ---------------------
# DB-IP's free country-lite CSV (CC BY 4.0; attribution in the dashboard
# footer and telemetry/README.md), fetched ONCE into the data volume at boot,
# parsed with the stdlib only (the image deliberately carries no extra python
# deps). Everything fails soft to "--": geolocation is a statistics nicety,
# never worth blocking on, and guest IPs are deliberately NEVER sent to any
# online lookup service (that would hand a third party the very data the
# notice promises to guard).
GEOCSV = DATA/"dbip-country-lite.csv.gz"
_geo = {"v4": [], "v6": [], "loaded": False}


def _geo_load():
    import gzip, csv as _csv, ipaddress, bisect
    if not GEOCSV.exists():
        # try current, then previous month (db-ip republishes monthly)
        from datetime import date
        months = []
        y, m = date.today().year, date.today().month
        months.append(f"{y}-{m:02d}")
        y2, m2 = (y, m - 1) if m > 1 else (y - 1, 12)
        months.append(f"{y2}-{m2:02d}")
        for mo in months:
            url = f"https://download.db-ip.com/free/dbip-country-lite-{mo}.csv.gz"
            ok, _ = run(f"curl -fsSL --max-time 60 -o {GEOCSV}.tmp {url}", t=90)
            if ok:
                Path(f"{GEOCSV}.tmp").replace(GEOCSV)
                print(f"geoip: fetched dbip-country-lite {mo}", flush=True)
                break
            Path(f"{GEOCSV}.tmp").unlink(missing_ok=True)
    if not GEOCSV.exists():
        print("geoip: no database (offline?); guest countries will read --", flush=True)
        return
    try:
        v4, v6 = [], []
        with gzip.open(GEOCSV, "rt") as f:
            for row in _csv.reader(f):
                if len(row) < 3:
                    continue
                try:
                    a, b = ipaddress.ip_address(row[0]), ipaddress.ip_address(row[1])
                except ValueError:
                    continue
                (v4 if a.version == 4 else v6).append((int(a), int(b), row[2]))
        v4.sort(); v6.sort()
        _geo["v4"], _geo["v6"], _geo["loaded"] = v4, v6, True
        print(f"geoip: loaded {len(v4)} v4 + {len(v6)} v6 ranges", flush=True)
    except Exception as e:
        print("geoip: load failed:", e, flush=True)


def geo_cc(ip):
    """Country code for an address, '--' when unknown. Pure stdlib bisect."""
    try:
        import ipaddress, bisect
        a = ipaddress.ip_address(ip)
        table = _geo["v4"] if a.version == 4 else _geo["v6"]
        if not table:
            return "--"
        i = bisect.bisect_right(table, (int(a), 2**129, "")) - 1
        if i >= 0 and table[i][0] <= int(a) <= table[i][1]:
            return table[i][2]
        return "--"
    except Exception:
        return "--"


def _redact_csv(path, ip_cols):
    """Shared redactor: IP columns expire past the retention window, rows
    stay as anonymised statistics."""
    try:
        if not path.exists():
            return
        cutoff = time.time() - GUEST_RETENTION_S
        rows = path.read_text().splitlines()
        out, changed = [], 0
        for r in rows:
            p = r.split(",")
            try:
                old = datetime.fromisoformat(p[0]).timestamp() < cutoff
            except Exception:
                old = False
            if old:
                for c in ip_cols:
                    if len(p) > c and p[c] not in ("-", ""):
                        p[c] = "-"; changed += 1
            out.append(",".join(p))
        if changed:
            tmp = path.with_suffix(".csv.tmp")
            tmp.write_text("\n".join(out) + "\n")
            tmp.replace(path)
            print(f"{path.name}: redacted {changed} IP field(s) past retention", flush=True)
    except Exception:
        pass


def _guest_log_expire_ips():
    """Redact the IP column of rows older than the retention window; the rows
    themselves stay forever as anonymised statistics (timestamp, name,
    country, duration, end reason). Cheap: a few KB once per collect cycle."""
    _redact_csv(REPORTCSV, [2, 4])     # publisher ip, reporter ip
    try:
        if not GUESTCSV.exists():
            return
        cutoff = time.time() - GUEST_RETENTION_S
        rows = GUESTCSV.read_text().splitlines()
        out, changed = [], 0
        for r in rows:
            p = r.split(",")
            # rows are ts,name,addr,cc,dur,reason (legacy rows lack cc)
            if len(p) >= 5 and p[2] not in ("-", ""):
                try:
                    if datetime.fromisoformat(p[0]).timestamp() < cutoff:
                        p[2] = "-"
                        changed += 1
                except Exception:
                    pass            # unparseable timestamp: leave untouched
            out.append(",".join(p))
        if changed:
            tmp = GUESTCSV.with_suffix(".csv.tmp")
            tmp.write_text("\n".join(out) + "\n")
            tmp.replace(GUESTCSV)
            print(f"guest log: redacted {changed} IP(s) past retention", flush=True)
    except Exception:
        pass


def _guest_log(reason):
    """One CSV row per finished session: contention and abuse stay visible.
    Country is resolved locally at write time (see _geo_load); the IP column
    expires after GUEST_RETENTION_DAYS (see _guest_log_expire_ips)."""
    try:
        start = _guest.get("start")
        dur = round(time.time() - start) if start else 0
        cc = geo_cc(_guest.get("addr") or "")
        with open(GUESTCSV, "a") as f:
            f.write(f"{now_iso()},{_guest.get('name')},{_guest.get('addr')},{cc},{dur},{reason}\n")
    except Exception:
        pass


def guest_public():
    """The publicly shown slice: no addr. remaining_s is cap time while live,
    reconnect window while in grace. None when the feature is disabled, so
    every status surface simply omits it."""
    if not GUEST_ENABLED:
        return None
    with _guest_lock:
        st, now = dict(_guest), time.time()
    out = {"state": st["state"], "name": st["name"], "grace_s": GUEST_GRACE_S,
           "remaining_s": None,
           # the disclaimer's numeric claims interpolate from these, so the
           # prose can never drift from the running config
           "max_h": round(GUEST_MAX_S / 3600, 1),
           "retention_days": GUEST_RETENTION_S // 86400,
           "ban_days": GUEST_BAN_DAYS}
    if st["state"] == "live" and st["start"]:
        out["remaining_s"] = max(0, round(GUEST_MAX_S - (now - st["start"])))
    elif st["state"] == "grace" and st["grace_started"]:
        out["remaining_s"] = max(0, round(GUEST_GRACE_S - (now - st["grace_started"])))
    cd = st.get("cooldown_until")
    if st["state"] == "free" and cd and now < cd:
        out["cooldown_s"] = round(cd - now)
    # surfaced for 10 minutes so the pusher can see WHY their session ended
    # (OBS reports a successful connection either way, so without this the
    # commonest failure, wrong audio layout, is also the most confusing)
    if st.get("last_end") and now - st["last_end"] < 600 and st.get("last_end_reason"):
        out["last_end_reason"] = st["last_end_reason"]
    return out


def _refresh_pub_endpoint():
    """Push the new endpoint state into status.json between collect cycles: the
    player badge must not lag a takeover by up to a minute."""
    pub = _pub_cache[0]
    ep = guest_public()
    if not pub or not ep:
        return
    try:
        pub = dict(pub); pub["endpoint"] = ep
        PUB.write_text(json.dumps(pub))
    except Exception:
        pass


def _grace_timer_arm(seconds):
    if _guest_timer[0]:
        _guest_timer[0].cancel()
    t = threading.Timer(max(0.5, seconds), guest_tick)
    t.daemon = True
    t.start()
    _guest_timer[0] = t


def _guest_end_locked(reason):
    """Caller holds _guest_lock. Returns to free and logs; resuming the loop is
    the caller's job AFTER releasing the lock (source_start probes docker)."""
    _guest_log(reason)
    if _guest_timer[0]:
        _guest_timer[0].cancel(); _guest_timer[0] = None
    # forced endings arm the cooldown; a natural stop (grace expiry) does
    # not, and neither does a stalled transcode: that is usually an innocent
    # misconfiguration whose fix should be retryable immediately
    cooldown = (time.time() + GUEST_COOLDOWN_S
                if reason in ("session cap", "operator kill") and GUEST_COOLDOWN_S > 0
                else None)
    if _stall_timer[0]:
        _stall_timer[0].cancel(); _stall_timer[0] = None
    _guest.update(state="free", name=None, addr=None, start=None,
                  last_seen=None, grace_started=None, kill=False,
                  terminating=None, cooldown_until=cooldown,
                  reports=0, last_report_alert=None,
                  last_end=time.time(), last_end_reason=reason)
    _guest_save()
    _resume_flag[0] = True
    print(f"guest session ended ({reason})"
          + (f"; cooldown {GUEST_COOLDOWN_S}s" if cooldown else ""), flush=True)


def _resume_after_guest():
    """Hand control back to the loop's NORMAL on-demand rule, evaluated now:
    with idling disabled the loop simply runs; with idling enabled it returns
    only if somebody is actually watching, otherwise the visitor flow starts it
    later, exactly as if the guest had never existed."""
    if _guest["state"] != "free":
        return
    # A cap/kill ends the session the instant on_publish_done arrives, which
    # can be BEFORE the dropped guest's relay finishes tearing down at
    # earshot. source_start would then see "publishing", no-op, and report
    # success, leaving the loop down with nothing left to retry (the exact
    # T4 failure in testing). Grace-expiry resumes never wait here: the
    # teardown finished long before the window closed.
    _earshot_unwound(6)
    if IDLE_STOP_MIN <= 0:
        r = source_start()
    else:
        vw = viewers(docker_ps())
        if (vw.get("any") or 0) > 0:
            r = source_start()
        else:
            idle_state(idle_accum=0.0)
            _resume_flag[0] = False
            print("guest slot free; loop stays idle (no viewers)", flush=True)
            _refresh_pub_endpoint()
            return
    # "already_publishing" here is the teardown race, not success: keep the
    # resume owed so the guest_tick backstop retries it.
    if r.get("ok") and r.get("state") != "already_publishing":
        _resume_flag[0] = False
    _refresh_pub_endpoint()


def guest_tick():
    """Timer target and per-cycle backstop: expire grace, catch a dead session
    whose on_update stopped arriving, retry an owed loop resume."""
    if not GUEST_ENABLED:
        return
    ended = None
    with _guest_lock:
        now = time.time()
        if _guest["state"] == "grace" and _guest["grace_started"]:
            if now - _guest["grace_started"] >= GUEST_GRACE_S:
                ended = "grace expired"
                _guest_end_locked(ended)
        elif _guest["state"] == "live":
            # update pings come every 10 s; 60 s of silence means ingest died or
            # the callback path broke mid-session. Treat as a disconnect.
            if _guest["last_seen"] and now - _guest["last_seen"] > 60:
                _guest.update(state="grace", grace_started=now)
                _guest_save()
                _grace_timer_arm(GUEST_GRACE_S)
                print("guest updates stopped; entering grace", flush=True)
        elif _guest["state"] == "handover":
            # a handover is seconds long; a slot stuck here means both the
            # flip and the publisher's done notification were lost
            if _guest["last_seen"] and now - _guest["last_seen"] > 30:
                _guest.update(state="grace", grace_started=now)
                _guest_save()
                _grace_timer_arm(GUEST_GRACE_S)
                print("stale handover; entering grace", flush=True)
    if ended or _resume_flag[0]:
        _resume_after_guest()


def _ingest_guest_publishing():
    """Does ingest's stat page show a publisher on the guest application?"""
    x = sh(f"curl -s --max-time 4 {INGEST_STAT}")
    seg = x.split("<name>guest</name>", 1)
    return len(seg) == 2 and "<publishing/>" in seg[1].split("</application>", 1)[0]


def _earshot_unwound(deadline_s):
    """Wait for earshot to have no publisher (the loop's relay fully gone) so
    the guest's exec transcoder never runs beside the loop's on one MPD."""
    end = time.time() + deadline_s
    while time.time() < end:
        if not stream_state()["publishing"]:
            return True
        time.sleep(0.3)
    return False


def guest_publish(name, addr):
    """on_publish for the guest app. 2xx accepts; anything else rejects."""
    if not GUEST_ENABLED:
        return 403
    # ban check first: blocks only rows that are active AND still carry an
    # IP AND are unexpired by the clock, all three explicit, so a stale
    # label after a missed sweep can never wrongly block anyone
    if _ban_blocks(addr):
        print(f"guest publish rejected (banned): {addr}", flush=True)
        return 403
    name = _guest_sanitize(name)
    with _guest_lock:
        if _guest["state"] in ("live", "handover"):
            print(f"guest publish rejected (busy): {name} from {addr}", flush=True)
            return 403
        cd = _guest.get("cooldown_until")
        if cd and time.time() < cd:
            print(f"guest publish rejected (cooldown {round(cd - time.time())}s left): "
                  f"{name} from {addr}", flush=True)
            return 403
        resumed_session = _guest["state"] == "grace"
        # claim the slot as "handover" before the slow unwind: a concurrent
        # second publish is rejected rather than racing us, and the status
        # pages can show "switching over" instead of pretending it is live.
        # A grace reconnect keeps the session clock AND any pending operator
        # kill: disconnecting must not launder a kill away.
        start = _guest["start"] if resumed_session and _guest["start"] else time.time()
        keep_kill = _guest["kill"] if resumed_session else False
        if _guest_timer[0]:
            _guest_timer[0].cancel(); _guest_timer[0] = None
        _guest.update(state="handover", name=name, addr=addr, start=start,
                      last_seen=time.time(), grace_started=None, kill=keep_kill,
                      terminating=None, cooldown_until=None)
        _guest_save()
    # Loop handover, serialised against source_start via _start_lock so a
    # visitor's start cannot interleave with the stop and connect the loop
    # underneath a freshly admitted guest. The stop is UNCONDITIONAL: a loop
    # container that was just started but whose ffmpeg has not yet reached
    # earshot is invisible to the stat probe, and skipping the stop for it was
    # exactly the two-writers hole. The whole hold stays under nginx-rtmp's
    # ~10 s netcall patience: docker stop -t 3 (<=3.5 s) + unwind (<=4 s).
    with _start_lock:
        source_stop("guest handover", kill_after_s=3)
        settled = _earshot_unwound(HANDOVER_S) and not source_container(running_only=True)
    if not settled:
        # could not clear the slot in time: refuse this publish but leave the
        # slot in grace with the loop already stopping, so an immediate manual
        # retry succeeds and an abandoned attempt still resumes the loop.
        with _guest_lock:
            _guest.update(state="grace", name=None, addr=None, start=None,
                          grace_started=time.time())
            _guest_save()
            _grace_timer_arm(GUEST_GRACE_S)
        print(f"guest handover timed out; slot in grace ({name} from {addr})", flush=True)
        _refresh_pub_endpoint()
        return 503
    # handover complete: flip to live, but only if the slot still belongs to
    # this publish (a pusher that died mid-unwind has already moved it to
    # grace via on_publish_done; do not resurrect it)
    with _guest_lock:
        if _guest["state"] == "handover" and _guest["name"] == name:
            _guest.update(state="live", last_seen=time.time())
            _guest_save()
        else:
            print(f"guest vanished during handover: {name}", flush=True)
            return 201          # its session is already closing; nothing to hold
    print(f"guest publishing: {name} from {addr}"
          + (" (reconnect)" if resumed_session else ""), flush=True)
    _guest_stall_arm()
    _refresh_pub_endpoint()
    return 201


def guest_done(name):
    """on_publish_done: enter the reconnect grace, or end at once if this
    session was being terminated (cap hit or operator kill)."""
    if not GUEST_ENABLED:
        return 200
    name = _guest_sanitize(name)
    ended = None
    with _guest_lock:
        if _guest["state"] not in ("live", "handover") \
                or (_guest["name"] and name != _guest["name"]):
            return 200                      # stale/zombie notification
        if _guest["terminating"]:
            ended = _guest["terminating"]
            _guest_end_locked(ended)
        else:
            _guest.update(state="grace", grace_started=time.time())
            _guest_save()
            _grace_timer_arm(GUEST_GRACE_S)
            print(f"guest disconnected: {name}; grace {GUEST_GRACE_S}s", flush=True)
    if ended:
        _resume_after_guest()
    else:
        _refresh_pub_endpoint()
    return 200


def guest_update(name):
    """on_update liveness ping. Non-2xx here makes nginx-rtmp drop the
    publisher: the enforcement point for the cap and the kill button."""
    if not GUEST_ENABLED:
        return 200
    name = _guest_sanitize(name)
    with _guest_lock:
        if _guest["state"] == "live":
            if _guest["name"] and name != _guest["name"]:
                # a publisher we did not admit (state lost + restored session):
                # drop it rather than let it shadow the tracked one
                return 403
            _guest["last_seen"] = time.time()
            if _guest["kill"]:
                # never clobber a reason set by whoever armed the kill (the
                # stall detector rides the same flag with its own reason)
                _guest["terminating"] = _guest["terminating"] or "operator kill"
                _guest_save()
                return 403
            if _guest["start"] and time.time() - _guest["start"] > GUEST_MAX_S:
                _guest["terminating"] = "session cap"
                _guest_save()
                return 403
            _guest_save()
            return 200
        if _guest["state"] == "free":
            # an update with no session: either telemetry lost its state (wiped
            # volume) with a genuine publisher still up, or a stale/forged ping.
            # Only adopt when ingest actually shows a guest publisher, so a
            # delayed ping cannot conjure a phantom session that blocks the slot.
            if not _ingest_guest_publishing():
                return 200
            _guest.update(state="live", name=name, start=time.time(),
                          last_seen=time.time())
            _guest_save()
            print(f"guest session adopted (no state): {name}", flush=True)
            return 200
        # grace, but a publisher is pinging: the done that opened this grace
        # raced a still-live session. Re-adopt it (same clock) so the grace
        # timer cannot expire under an active publisher and restart the loop
        # beside it. Verified against ingest so a delayed ping cannot revive
        # a session whose publisher is truly gone.
        if _guest["state"] == "grace":
            if not _ingest_guest_publishing():
                return 200
            if _guest_timer[0]:
                _guest_timer[0].cancel(); _guest_timer[0] = None
            _guest.update(state="live", name=name, last_seen=time.time(),
                          grace_started=None,
                          start=_guest["start"] or time.time())
            _guest_save()
            print(f"guest re-adopted from grace on update ping: {name}", flush=True)
    return 200


def guest_kill():
    """Dashboard button. A live publisher is dropped at its next update ping
    (<= 10 s); a grace slot is reclaimed immediately."""
    if not GUEST_ENABLED:
        return {"ok": False, "state": "disabled"}
    ended = None
    with _guest_lock:
        if _guest["state"] in ("live", "handover"):
            _guest["kill"] = True
            _guest_save()
            return {"ok": True, "state": "ending", "within_s": 10}
        if _guest["state"] == "grace":
            ended = "operator kill"
            _guest_end_locked(ended)
    if ended:
        _resume_after_guest()
        return {"ok": True, "state": "ended"}
    return {"ok": True, "state": "free"}


# --- ban store ---------------------------------------------------------
# guest_bans.csv rows: banned_at,ip,cc,expires_at,reason,state
# Three end states: active (enforced, IP present), unbanned (lifted early,
# IP kept until redaction, NOT enforced), expired (retention elapsed, IP
# redacted in the same operation that writes the label, NOT enforced).
# Enforcement deliberately does NOT trust the label alone: it blocks only
# rows that are active AND still carry an IP AND whose expires_at is in the
# future, so a stale label after a missed job cycle can never cause a
# wrongful block.

_bans_lock = threading.Lock()

def _bans_read():
    rows = []
    try:
        for line in BANSCSV.read_text().splitlines():
            p = line.split(",")
            if len(p) >= 6:
                rows.append({"banned_at": p[0], "ip": p[1], "cc": p[2],
                             "expires_at": p[3], "reason": p[4], "state": p[5]})
    except FileNotFoundError:
        pass
    except Exception:
        pass
    return rows

def _bans_write(rows):
    tmp = BANSCSV.with_suffix(".csv.tmp")
    tmp.write_text("".join(
        f'{r["banned_at"]},{r["ip"]},{r["cc"]},{r["expires_at"]},{r["reason"]},{r["state"]}\n'
        for r in rows))
    tmp.replace(BANSCSV)

def _ban_blocks(ip):
    """The enforcement rule, all three conditions explicit."""
    if not ip:
        return False
    now = time.time()
    for r in _bans_read():
        if r["state"] != "active":
            continue
        if r["ip"] in ("-", "") or r["ip"] != ip:
            continue
        try:
            if datetime.fromisoformat(r["expires_at"]).timestamp() > now:
                return True
        except Exception:
            continue
    return False

def _bans_expire():
    """Retention-window sweep: past-retention rows lose their IP, and rows
    still labelled active get state=expired IN THE SAME WRITE, so the CSV
    stays self-describing (unbanned rows keep their outcome label)."""
    with _bans_lock:
        rows = _bans_read()
        if not rows:
            return
        cutoff = time.time() - GUEST_RETENTION_S
        changed = 0
        for r in rows:
            try:
                old = datetime.fromisoformat(r["banned_at"]).timestamp() < cutoff
            except Exception:
                old = False
            if not old:
                continue
            if r["ip"] not in ("-", ""):
                r["ip"] = "-"; changed += 1
            if r["state"] == "active":
                r["state"] = "expired"; changed += 1
        if changed:
            _bans_write(rows)
            print(f"guest_bans.csv: {changed} field(s) expired/redacted", flush=True)

def guest_ban():
    """Dashboard 'End + ban': ban the current session's address, then ride
    the normal kill path. Works in grace too (the publisher is gone but the
    session, and its address, still exist)."""
    if not GUEST_ENABLED:
        return {"ok": False, "error": "guest endpoint disabled"}
    with _guest_lock:
        if _guest["state"] not in ("live", "handover", "grace"):
            return {"ok": False, "error": "no active session"}
        addr, name = _guest.get("addr"), _guest.get("name")
    if not addr:
        return {"ok": False, "error": "session has no recorded address"}
    now = datetime.now().astimezone()
    exp = now + timedelta(days=GUEST_BAN_DAYS)
    with _bans_lock:
        rows = _bans_read()
        rows.append({"banned_at": now.isoformat(timespec="seconds"),
                     "ip": addr, "cc": geo_cc(addr),
                     "expires_at": exp.isoformat(timespec="seconds"),
                     "reason": "operator ban", "state": "active"})
        _bans_write(rows)
    print(f"guest banned: {addr} until {exp.isoformat(timespec='seconds')} "
          f"(session '{name}')", flush=True)
    out = guest_kill()
    out["banned"] = addr
    return out

def guest_unban(ip):
    if not GUEST_ENABLED:
        return {"ok": False, "error": "guest endpoint disabled"}
    if not ip:
        return {"ok": False, "error": "ip required"}
    with _bans_lock:
        rows = _bans_read()
        hit = 0
        for r in rows:
            if r["state"] == "active" and r["ip"] == ip:
                r["state"] = "unbanned"; hit += 1
        if hit:
            _bans_write(rows)
    print(f"guest unban: {ip} ({hit} row(s))", flush=True)
    return {"ok": bool(hit), "unbanned": hit}

def _bans_lists():
    """Dashboard split: active = the enforcement view (same triple rule, so
    a stale label can never grow an Unban button on a redacted row);
    history = everything else, no IPs, outcome computed by time when the
    label lags the clock."""
    now = time.time()
    active, history = [], []
    for r in _bans_read():
        live = False
        if r["state"] == "active" and r["ip"] not in ("-", ""):
            try:
                live = datetime.fromisoformat(r["expires_at"]).timestamp() > now
            except Exception:
                live = False
        if live:
            active.append({"ip": r["ip"], "cc": r["cc"], "banned_at": r["banned_at"],
                           "expires_at": r["expires_at"], "reason": r["reason"]})
        else:
            outcome = r["state"]
            if r["state"] == "active":
                outcome = "expired"          # label lagging a missed sweep
            history.append({"cc": r["cc"], "banned_at": r["banned_at"],
                            "expires_at": r["expires_at"], "reason": r["reason"],
                            "outcome": outcome})
    return {"active": active, "history": history}


def _guest_stall_arm():
    """One-shot check GUEST_STALL_S after a session goes live: if no playable
    segment has appeared, the transcoder is stalled (in practice: the pusher
    sent stereo/mono where 16-channel audio is required) and the session would
    otherwise squat the slot for the full cap with nothing playing. End it and
    surface the reason (drill finding: the commonest real failure was also the
    most confusing, because OBS reports a successful connection)."""
    if _stall_timer[0]:
        _stall_timer[0].cancel()
    def check():
        with _guest_lock:
            if _guest["state"] != "live":
                return
            age = segment_age()
            if age is not None and age < SEG_STALE_S:
                return              # segments flowing; healthy session
            _guest["terminating"] = "no playable output (16-channel audio required)"
            _guest["kill"] = True   # dropped at the next update ping
            _guest_save()
        print("guest transcode stalled; ending the session "
              "(wrong audio layout is the usual cause)", flush=True)
        telegram(f"guest stream '{_guest.get('name')}' ended automatically: "
                 "no playable output (wrong audio layout?)")
    t = threading.Timer(GUEST_STALL_S, check)
    t.daemon = True
    t.start()
    _stall_timer[0] = t


def guest_report(reporter_ip, reporter_cc):
    """The player's report button. Rate limits: nginx already brakes per
    viewer IP; here, at most REPORT_IP_MAX accepted per reporter IP per
    window, and one Telegram alert per session per REPORT_COOLDOWN_S with an
    escalating count. Reporter IPs land in guest_reports.csv under the same
    30-day redaction as everything else."""
    if not GUEST_ENABLED:
        return 404, {"ok": False}
    now = time.time()
    with _guest_lock:
        if _guest["state"] not in ("live", "handover", "grace"):
            return 409, {"ok": False, "reason": "no active session"}
        hits = [t for t in _reporters.get(reporter_ip, []) if now - t < REPORT_IP_WINDOW_S]
        if len(hits) >= REPORT_IP_MAX:
            return 429, {"ok": False, "reason": "already reported"}
        hits.append(now)
        _reporters[reporter_ip] = hits
        _guest["reports"] += 1
        n = _guest["reports"]
        alert = (_guest["last_report_alert"] is None
                 or now - _guest["last_report_alert"] > REPORT_COOLDOWN_S)
        if alert:
            _guest["last_report_alert"] = now
        name, addr, start = _guest.get("name"), _guest.get("addr"), _guest.get("start")
        _guest_save()
    pub_cc = geo_cc(addr or "")
    rep_cc = reporter_cc or geo_cc(reporter_ip or "")
    try:
        with open(REPORTCSV, "a") as f:
            f.write(f"{now_iso()},{name},{addr},{pub_cc},{reporter_ip},{rep_cc},{1 if alert else 0}\n")
    except Exception:
        pass
    if alert:
        elapsed = dur_short(now - start) if start else "?"
        started = datetime.fromtimestamp(start).astimezone().isoformat(timespec="seconds") if start else "?"
        # no dashboard mention in the body: the telegram() tail appends the
        # actual link, and its 8090-dedup guard must not be tripped here
        telegram(f"guest stream REPORTED: '{name}' from {addr} ({pub_cc})\n"
                 f"started {started}, running {elapsed}\n"
                 f"reporter: {reporter_ip} ({rep_cc})\n"
                 f"reports so far: {n}")
    return 200, {"ok": True, "reported": True}


# Service restarts from the dashboard. Same trust boundary as /api/stop.
# earshot is only offered TOGETHER with ingest: nginx-rtmp resolves the push
# hostname once at startup, so a lone earshot restart silently breaks the
# relay (the standing rule, now encoded rather than remembered).
RESTARTABLE = {"rtmp-ingest": ["rtmp-ingest"],
               "hoast-player": ["hoast-player"],
               "telemetry": ["telemetry"],
               "earshot-ingest": ["earshot", "rtmp-ingest"]}


def _service_container(svc):
    out = sh(f'docker ps -a --filter "label=com.docker.compose.project={PROJECT}" '
             f'--filter "label=com.docker.compose.service={svc}" '
             f'--filter "label=com.docker.compose.oneoff=False" --format "{{{{.Names}}}}"')
    lines = [l for l in out.strip().splitlines() if l.strip()]
    return lines[0] if lines else ""


def restart_services(key):
    plan = RESTARTABLE.get(key)
    if not plan:
        return {"ok": False, "error": "unknown service"}
    names = [(_service_container(svc), svc) for svc in plan]
    missing = [svc for (n, svc) in names if not n]
    if missing:
        return {"ok": False, "error": "container not found: " + ", ".join(missing)}
    def do():
        for n, svc in names:
            sh(f"docker restart {n}", t=90)
            print(f"dashboard restart: {svc} ({n})", flush=True)
    if key == "telemetry":
        # respond first, restart ourselves after the reply has left
        threading.Timer(0.5, do).start()
        return {"ok": True, "state": "restarting", "note": "telemetry back in ~10 s"}
    do()
    return {"ok": True, "state": "restarted", "services": plan}


def _guest_boot():
    """Reload persisted state and reconcile it against reality: a session that
    died while telemetry was down must not hold the slot forever."""
    if not GUEST_ENABLED:
        return
    try:
        st = json.loads(GSTATE.read_text())
        with _guest_lock:
            _guest.update({k: st.get(k, _guest[k]) for k in _guest})
    except Exception:
        return
    with _guest_lock:
        if _guest["state"] in ("live", "handover"):
            if not _ingest_guest_publishing():
                _guest.update(state="grace", grace_started=time.time())
                _guest_save()
                _grace_timer_arm(GUEST_GRACE_S)
                print("guest session not found on ingest after restart; grace", flush=True)
            elif _guest["state"] == "handover":
                # publisher exists and we died mid-flip: it is effectively live
                _guest.update(state="live", last_seen=time.time())
                _guest_save()
        elif _guest["state"] == "grace" and _guest["grace_started"]:
            left = GUEST_GRACE_S - (time.time() - _guest["grace_started"])
            _grace_timer_arm(max(0.5, left))


def stream_format():
    """Everything the panels report about the stream, read from the live MPD.

    The manifest is ground truth. Deriving these from FFMPEG_FLAGS instead
    reports what the encoder was told to do, which is wrong whenever the video is
    stream-copied (no scale= or -b:v appears in the flags at all) and stale
    whenever the config changes without recreating this container. Reading the
    manifest also means an arbitrary stream pointed at this server is described
    correctly, including a different ambisonic order.

    Note the ACN/SN3D ordering is a stack convention rather than something the
    stream signals: the audio is Opus mapping family 255 (discrete channels), so
    only the channel COUNT is carried. Order is inferred from it.
    """
    out = {"resolution": None, "video_bitrate": None, "audio_bitrate": None,
           "video_codec": None, "audio_codec": None, "audio_channels": None,
           "sample_rate": None, "ambisonic_order": None, "spatial_audio": None}
    try:
        mpds = sorted(DASH.glob("*.mpd"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not mpds:
            return out
        root = ET.parse(mpds[0]).getroot()
        vid, aud = [], []
        for aset in root.iter():
            if not aset.tag.endswith("AdaptationSet"):
                continue
            aw, ah = aset.get("width"), aset.get("height")   # may sit on either element
            for rep in aset:
                if not rep.tag.endswith("Representation"):
                    continue
                bw = rep.get("bandwidth")
                if not bw:
                    continue
                cod = rep.get("codecs") or aset.get("codecs")
                w, h = rep.get("width") or aw, rep.get("height") or ah
                if w and h:
                    vid.append((int(bw), w, h, cod))
                else:
                    ch = None
                    for kid in rep:
                        if kid.tag.endswith("AudioChannelConfiguration") and kid.get("value"):
                            ch = int(kid.get("value"))
                    aud.append((int(bw), cod, ch, rep.get("audioSamplingRate")))
        if vid:
            vbw, w, h, vcod = max(vid, key=lambda t: t[0])
            out.update(resolution=f"{w}x{h}", video_bitrate=vbw, video_codec=codec_name(vcod))
        if aud:
            abw, acod, ch, sr = max(aud, key=lambda t: t[0])
            out.update(audio_bitrate=abw, audio_channels=ch,
                       audio_codec=(acod.split(".")[0].capitalize() if acod else None),
                       sample_rate=int(sr) if sr else None)
            if ch:
                r = int(round(ch ** 0.5))
                if r * r == ch and r >= 2:       # perfect square => a full ambisonic set
                    n = r - 1
                    suffix = {1: "st", 2: "nd", 3: "rd"}.get(n, "th")
                    out["ambisonic_order"] = n
                    out["spatial_audio"] = f"{n}{suffix}-order Ambisonics"
        return out
    except Exception:
        return out


def mbps(bps):
    """None means unknown and renders as a dash; 0 is a real answer. A live stream
    with nobody watching has an egress of zero, which is worth stating."""
    return f"{bps / 1_000_000:.1f} Mbps" if bps is not None else None


def codec_name(c):
    """avc1.640033 -> H.264, av01.0.08M.08 -> AV1, vp09/vp9 -> VP9."""
    if not c:
        return None
    c = c.lower()
    for pfx, name in (("avc", "H.264"), ("hev", "HEVC"), ("hvc", "HEVC"),
                      ("av01", "AV1"), ("vp9", "VP9"), ("vp09", "VP9"), ("vp8", "VP8")):
        if c.startswith(pfx):
            return name
    return c.split(".")[0]


def telegram(msg):
    if not BOT or not CHAT:
        return
    # Dashboard link tail. Telegram only auto-linkifies hostnames with a
    # real TLD (IPs work, bare "example-host" never does), so deployments
    # set TEL_DASH_URL to a resolvable full URL (e.g. the Tailscale MagicDNS
    # name); plain text needs no parse_mode and nothing to escape.
    tail = os.environ.get("TEL_DASH_URL", "")
    if not tail:
        _h = os.environ.get("TEL_HOST", "")
        tail = f"http://{_h}:8090/" if _h else ""
    if tail and "8090" not in msg:
        msg = f"{msg}\n{tail}"
    data = urllib.parse.urlencode({"chat_id": CHAT, "text": msg}).encode()
    try:
        urllib.request.urlopen(f"https://api.telegram.org/bot{BOT}/sendMessage", data=data, timeout=10)
    except Exception:
        pass

def dur_short(sec):
    """Compact episode length: 45s, 4m, 1h12m."""
    sec = int(sec)
    if sec < 60:
        return f"{sec}s"
    if sec < 3600:
        return f"{sec // 60}m"
    return f"{sec // 3600}h{(sec % 3600) // 60:02d}m"


# How to phrase the worst reading of an episode, per condition. Telegram stamps
# every message with its own send time, so a timestamp in the body would only
# duplicate what is printed directly above it. What the stamps cannot show at a
# glance is how long the problem lasted and how bad it got, which is what the
# recovery line carries instead.
WORST_FMT = {
    "encoder_behind": lambda v: f"worst {v:.2f}x",
    "overheat":       lambda v: f"peak {v}°C",
    "disk_full":      lambda v: f"peak {v}%",
    "stream_stalled": lambda v: f"worst {v}s stale",
}


def tunnel_probe():
    """Cloudflared health via its local metrics server: /ready gives the
    connection count, /metrics the edge locations. The tunnel dropping is the
    one failure where the box looks healthy to itself while being unreachable
    to everyone else, hence its own panel and alert."""
    if not TUNNEL_METRICS_URL:
        return None
    # connected: True/False from a successful metrics read; None when the
    # metrics endpoint itself is unreachable. The distinction matters for the
    # alert: an unreachable metrics port must read as UNKNOWN, never as
    # "tunnel down", or a probe misconfiguration would page the operator.
    out = {"connected": None, "conns": 0, "locations": [],
           "checked": now_iso()}
    try:
        r = urllib.request.urlopen(f"{TUNNEL_METRICS_URL}/ready", timeout=4)
        j = json.loads(r.read().decode())
        out["conns"] = int(j.get("readyConnections", 0))
        out["connected"] = out["conns"] > 0
    except urllib.error.HTTPError as e:
        # cloudflared answers 503 on /ready when it has no connections:
        # that IS a definite "down", not an unknown
        if e.code == 503:
            out["connected"] = False
        return out
    except Exception:
        return out
    try:
        m = urllib.request.urlopen(f"{TUNNEL_METRICS_URL}/metrics", timeout=4).read().decode()
        locs = set()
        for line in m.splitlines():
            if line.startswith("cloudflared_tunnel_server_locations{") and line.rstrip().endswith(" 1"):
                i = line.find('edge_location="')
                if i >= 0:
                    locs.add(line[i + 15:line.index('"', i + 15)])
        out["locations"] = sorted(locs)
    except Exception:
        pass
    return out


def vod_origin_probe():
    """HEAD on one known VOD object. Not a usage metric, just reachable or
    not; if it fails, the actionable response is removing vodBase from
    brand.json so the player falls back to box-served VOD."""
    if not VOD_PROBE_URL:
        return None
    out = {"ok": False, "code": None, "checked": now_iso(), "url": VOD_PROBE_URL}
    try:
        # Cloudflare's bot rules 403 the default Python-urllib agent
        req = urllib.request.Request(VOD_PROBE_URL, method="HEAD",
                                     headers={"User-Agent": "hoa360-telemetry/1.0"})
        r = urllib.request.urlopen(req, timeout=6)
        out["code"] = r.status
        out["ok"] = 200 <= r.status < 400
    except urllib.error.HTTPError as e:
        out["code"] = e.code
    except Exception:
        pass
    return out


def evaluate_alerts(s):
    try:
        state = json.loads(STATE.read_text())
    except Exception:
        state = {}
    counts, fired = state.get("_counts", {}), state.get("_fired", {})
    since, worst = state.get("_since", {}), state.get("_worst", {})
    active, msgs = [], []
    down = [f"{x['name']} ({x.get('health') or x.get('state') or 'down'})"
            for x in s["services"] if not x["healthy"]]
    d, t = s["system"]["disk_used_pct"], s["system"]["temp_c"]
    st = s["stream"]
    stalled = bool(st["publishing"] and st["segment_age_s"] is not None and st["segment_age_s"] > SEG_STALE_S)
    # Trailing pair is the reading to track across the episode and whether lower
    # or higher is worse, so the recovery line can report how bad it got.
    conds = {
        "services_down":  (bool(down), "service(s) unhealthy: " + ", ".join(down), "all services healthy again", None, None),
        "disk_full":      (d is not None and d >= DISK_FULL_PCT, f"disk {d}% full", "disk usage back to normal", d, "max"),
        "overheat":       (t is not None and t >= TEMP_CRIT_C, f"CPU {t}°C, nearing 105°C critical", "CPU temp back below 100°C", t, "max"),
        "encoder_behind": (s["encoder"]["behind"], f"encoder behind realtime ({s['encoder']['speed']}x)", "encoder keeping up again", s["encoder"]["speed"], "min"),
        "stream_stalled": (stalled, f"stream publishing but segments {st['segment_age_s']}s stale", "stream flowing again", st["segment_age_s"], "max"),
        "tunnel_down":    (bool(s.get("tunnel")) and s["tunnel"]["connected"] is False, "cloudflared tunnel DISCONNECTED: box healthy but unreachable from outside", "tunnel reconnected", (s.get("tunnel") or {}).get("conns"), "min"),
    }
    for key, (cond, problem, recovered, metric, worse) in conds.items():
        counts[key] = (counts.get(key, 0) + 1) if cond else 0
        if cond and metric is not None:
            prev = worst.get(key)
            if prev is None or (metric < prev if worse == "min" else metric > prev):
                worst[key] = metric
        if cond and counts[key] >= DEBOUNCE and not fired.get(key):
            msgs.append("🔴 " + problem)
            fired[key] = True
            since[key] = time.time()
        elif not cond and fired.get(key):
            bits = []
            if since.get(key):
                bits.append(dur_short(time.time() - since[key]))
            w = worst.get(key)
            if w is not None and key in WORST_FMT:
                bits.append(WORST_FMT[key](w))
            msgs.append("✅ " + recovered + (f" ({', '.join(bits)})" if bits else ""))
            fired[key] = False
        if not cond:                       # episode over, whether or not it fired
            since.pop(key, None)
            worst.pop(key, None)
        if fired.get(key):
            active.append(key)
    state["_counts"], state["_fired"] = counts, fired
    state["_since"], state["_worst"] = since, worst
    STATE.write_text(json.dumps(state))
    for m in msgs:
        telegram(f"🎛️ {HOST}: {m}")
    return active

def history():
    out = []
    try:
        for l in CSV.read_text().splitlines()[-180:]:
            p = l.split(",")
            if len(p) >= 3:
                out.append({"t": p[0],
                            # empty means the viewer probe failed that cycle,
                            # which is not an audience of zero. int("") would
                            # raise and the outer except would drop the entire
                            # history, not just the one row.
                            "v": (int(p[1]) if p[1] not in ("", "None") else None),
                            "temp": (float(p[2]) if p[2] not in ("", "None") else None),
                            # field 4 has always been written and never read.
                            # With on-demand idling it answers the new question:
                            # what fraction of the window was the box encoding?
                            "live": (int(p[3]) if len(p) > 3 and p[3] in ("0", "1") else None)})
    except Exception:
        pass
    return out

def collect_once():
    ps = docker_ps()
    svcs = services(ps)
    strm = stream_state()
    fmt = stream_format()
    per_viewer = (fmt["video_bitrate"] or 0) + (fmt["audio_bitrate"] or 0)   # what ONE client pulls
    vw = viewers(ps)
    s = {
        "ts": now_iso(), "host": HOST, "services": svcs,
        "all_healthy": all(x["healthy"] for x in svcs) if svcs else False,
        "stream": strm, "encoder": encoder(ps, strm["publishing"]),
        "viewers": vw, "bitrate": mbps(per_viewer or None), **fmt,
        # per-viewer x clients = server load. Zero viewers on a live stream is a
        # real zero; no stream at all is unknown.
        "egress": mbps(per_viewer * vw["now"] if per_viewer else None),
        "system": {"temp_c": temp_c(), "load1": load1(), "mem_used_pct": mem_pct(),
                   "disk_used_pct": disk_pct(), "uptime_s": uptime_s(),
                   "cores": os.cpu_count()},
    }
    _note_live(strm["live"])            # keep readiness tracked even if nobody polls /api/live
    s["on_demand"] = IDLE_STOP_MIN > 0
    s["idle_stop_min"] = IDLE_STOP_MIN
    # via source_container, not container_named: a one-off `compose run` pusher
    # (pipeline/guest tests) also carries the loop-source service label and
    # would read as the source running while the real one is stopped
    s["source_running"] = bool(source_container(running_only=True))
    tn = tunnel_probe()
    if tn is not None:
        s["tunnel"] = tn
    vp = vod_origin_probe()
    if vp is not None:
        s["vod_origin"] = vp
    s["alerts_active"] = evaluate_alerts(s)
    guest_tick()                        # backstop for the grace/cap timers
    _guest_log_expire_ips()             # 30-day IP redaction; rows stay as stats
    _bans_expire()                      # same event: ban expiry = IP redaction
    ep = guest_public()
    if ep:
        s["endpoint"] = {**ep, "addr": _guest.get("addr")}   # addr: private page only
        s["bans"] = _bans_lists()                            # private page only
    auto_idle(strm, vw.get("any", vw["now"]))
    # Read back after the decision so the panel shows the current countdown
    # rather than last cycle's.
    last_seen, accum = idle_state()
    s["last_viewer_s"] = round(time.time() - last_seen) if last_seen else None
    s["idle_stops_in_s"] = (max(0, round(IDLE_STOP_MIN * 60 - accum))
                            if IDLE_STOP_MIN > 0 and strm["publishing"] else None)
    cc = ";".join(f"{k}:{v}" for k, v in s["viewers"].get("countries", {}).items())
    with open(CSV, "a") as f:
        f.write(f"{s['ts']},{s['viewers']['now']},{s['system']['temp_c']},{1 if strm['live'] else 0},{cc}\n")
    s["history"] = history()
    tmp = STATS.with_suffix(".json.tmp"); tmp.write_text(json.dumps(s, indent=1)); tmp.replace(STATS)
    # Deliberately no egress here: aggregate server load is an operator metric, and
    # the per-viewer figure is the only bitrate a visitor can act on.
    pub = {"ts": s["ts"], "live": strm["live"], "publishing": strm["publishing"],
           "resolution": fmt["resolution"], "bitrate": mbps(per_viewer or None),
           "video_codec": fmt["video_codec"], "audio_codec": fmt["audio_codec"],
           "audio_channels": fmt["audio_channels"], "spatial_audio": fmt["spatial_audio"],
           "on_demand": s["on_demand"], "idle_stop_min": IDLE_STOP_MIN,
           "source_running": s["source_running"], "viewers": s["viewers"]["now"],
           "countries": s["viewers"].get("countries", {}), "uptime_s": s["system"]["uptime_s"],
           **({"endpoint": ep} if ep else {})}
    _pub_cache[0] = pub               # for out-of-cycle endpoint refreshes
    PUB.write_text(json.dumps(pub))   # in-place: stable inode for the hoast-player bind mount


def serve():
    DATA.mkdir(parents=True, exist_ok=True)
    class H(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k): super().__init__(*a, directory=str(DATA), **k)
        def log_message(self, *a): pass

        def end_headers(self):
            # The dashboard is redeployed often and the browser was holding onto
            # an old copy, so changes appeared not to have shipped. stats.json is
            # already fetched with a cache-buster; the HTML was not.
            p = self.path.split("?")[0]
            if p.endswith("/") or p.endswith(".html"):
                self.send_header("Cache-Control", "no-cache, must-revalidate")
            super().end_headers()

        def _json(self, code, obj):
            b = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            p, _, q = self.path.partition("?")
            if p == "/api/live":
                return self._json(200, live_probe())
            # nginx-rtmp notify callbacks for the guest app, proxied here by
            # rtmp-ingest (notify_method get). The status code IS the answer:
            # 2xx allows the publish / keeps the stream, anything else rejects
            # or drops it.
            if p.startswith("/rtmp/guest/"):
                args = urllib.parse.parse_qs(q)
                name = (args.get("name") or [""])[0]
                addr = (args.get("addr") or [""])[0]
                call = (args.get("call") or [""])[0]
                act = p.rsplit("/", 1)[-1]
                if act == "publish":
                    return self._json(guest_publish(name, addr), {})
                if act == "done":
                    return self._json(guest_done(name), {})
                if act == "update":
                    # on_update fires for PLAYERS too (call=update_play); only
                    # a publisher's ping may drive session liveness, or a mere
                    # viewer would keep a dead session alive or get adopted
                    if call and call != "update_publish":
                        return self._json(200, {})
                    return self._json(guest_update(name), {})
            return super().do_GET()

        def do_POST(self):
            p = self.path.split("?")[0]
            if p == "/api/start":
                return self._json(200, source_start())
            # /api/stop is reachable only on this port, which is bound to
            # localhost/VPN. It is never proxied to the public player, because
            # stopping is the one verb a visitor could use to ruin the demo for
            # everyone else.
            if p == "/api/stop":
                return self._json(200, source_stop("manual"))
            # End the current guest session (dashboard button). Same trust
            # boundary as /api/stop: this port only.
            if p == "/api/guest/kill":
                return self._json(200, guest_kill())
            if p == "/api/guest/ban":
                return self._json(200 if GUEST_ENABLED else 404, guest_ban())
            if p == "/api/guest/unban":
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                return self._json(200 if GUEST_ENABLED else 404,
                                  guest_unban((q.get("ip") or [""])[0]))
            # Abuse report, proxied from the public player with the real
            # reporter identity in headers (nginx cf-aware maps)
            if p == "/api/guest/report":
                code, body = guest_report(
                    self.headers.get("X-Viewer-IP", self.client_address[0]),
                    self.headers.get("X-Viewer-CC", ""))
                return self._json(code, body)
            # Dashboard service restarts (private port only). earshot ships
            # only as the earshot-ingest pair; see RESTARTABLE.
            # on-demand reachability re-check (dashboard button): runs both
            # probes now and returns fresh results without waiting a cycle
            if p == "/api/probe":
                return self._json(200, {"tunnel": tunnel_probe(),
                                        "vod_origin": vod_origin_probe()})
            if p == "/api/restart":
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                return self._json(200, restart_services((q.get("svc") or [""])[0]))
            return self._json(404, {"ok": False, "error": "not found"})

    with socketserver.ThreadingTCPServer(("", PORT), H) as srv:
        srv.allow_reuse_address = True
        srv.serve_forever()

def main():
    DATA.mkdir(parents=True, exist_ok=True)
    # dashboard.html is baked into the image at /app/web/index.html; expose it in DATA
    src = Path("/app/web/index.html")
    if src.exists():
        html = src.read_text()
        # Optional deployment favicon: the same brand.json the player uses, mounted
        # here read-only. Absent means the committed generic icon stays, so reusers
        # get the default without editing a tracked file.
        try:
            bp = Path(os.environ.get("TEL_BRAND", "/app/brand.json"))
            brand = json.loads(bp.read_text()) if bp.exists() else {}
        except Exception:
            brand = {}
        fav = brand.get("favicon")
        if fav:
            html = re.sub(r'(<link rel="icon" href=")[^"]*(">)',
                          lambda m: m.group(1) + fav + m.group(2), html, count=1)
        # Branded launcher buttons (loop-source row): the link list is baked into
        # the page; the host (and an optional link override) come from the same
        # brand.json, so one file points these buttons at this deployment's
        # address. Absent -> host falls back client-side to the URL reached on.
        if brand.get("host") or brand.get("boxLinks"):
            def _box(m):
                try:
                    box = json.loads(m.group(2))
                except Exception:
                    return m.group(0)
                if brand.get("host"):     box["host"]  = brand["host"]
                if brand.get("boxLinks"): box["links"] = brand["boxLinks"]
                return m.group(1) + json.dumps(box) + m.group(3)
            html = re.sub(r'(window\.__BOX__\s*=\s*)(\{.*\})(;)', _box, html, count=1)
        (DATA/"index.html").write_text(html)
    _guest_boot()      # restore a guest session across telemetry restarts
    threading.Thread(target=_geo_load, daemon=True).start()   # fail-soft geoip
    threading.Thread(target=serve, daemon=True).start()
    while True:
        try:
            collect_once()
        except Exception as e:
            print("collect error:", e, flush=True)
        time.sleep(INTERVAL)

if __name__ == "__main__":
    main()
