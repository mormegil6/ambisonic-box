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
from datetime import datetime
from pathlib import Path

HOST     = os.environ.get("TEL_HOST", "example-host")
PROJECT  = os.environ.get("COMPOSE_PROJECT_NAME", "hoa360")
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
_idle_cycles = [0]
_src_cache = [0.0, False]   # (checked_at, running) for live_probe
_live_since = [None]        # epoch the stream last became live, for readiness

# A player pinned to a 30 s live delay cannot start on a timeline shorter than
# that: dash.js throws "Cannot read properties of null (reading 'range')" and
# never recovers. Measured on the box, a cold start reaches fresh segments at
# t+6 s but only plays once ~35 s of history exists (first frame t+43 s). So
# liveness is not readiness, and the player must not initialise until this.
READY_S = int(os.environ.get("TEL_READY_S", "35"))


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
    idle timer stops it, `docker ps` alone can no longer find it to start again."""
    flag = "" if running_only else "-a "
    out = sh(f'docker ps {flag}--filter "label=com.docker.compose.project={PROJECT}" '
             f'--filter "label=com.docker.compose.service={SOURCE_SVC}" --format "{{{{.Names}}}}"')
    lines = [l for l in out.strip().splitlines() if l.strip()]
    return lines[0] if lines else ""


def source_start():
    """Start the loop source. Idempotent by design: that is what makes it safe to
    expose publicly, since the worst a flood achieves is the stream running, which
    is the normal state anyway. Stopping stays private."""
    with _start_lock:
        if time.time() - _last_start[0] < 15:
            return {"ok": True, "state": "starting"}          # coalesce a burst of clicks
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


def source_stop(reason="manual"):
    name = source_container(running_only=True)
    if not name:
        return {"ok": True, "state": "already_stopped"}
    sh(f"docker stop {name}", t=40)
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
            "starting": now - _last_start[0] < 120}


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
    s["source_running"] = bool(container_named(ps, SOURCE_SVC))
    s["alerts_active"] = evaluate_alerts(s)
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
           "countries": s["viewers"].get("countries", {}), "uptime_s": s["system"]["uptime_s"]}
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
            if self.path.split("?")[0] == "/api/live":
                return self._json(200, live_probe())
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
    threading.Thread(target=serve, daemon=True).start()
    while True:
        try:
            collect_once()
        except Exception as e:
            print("collect error:", e, flush=True)
        time.sleep(INTERVAL)

if __name__ == "__main__":
    main()
