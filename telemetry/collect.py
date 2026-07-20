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
# docker CLI (installed in the image; socket mounted read-only).
import json, os, re, subprocess, time, ipaddress, threading
import http.server, socketserver, urllib.parse, urllib.request
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
PUBDIR = Path(os.environ.get("TEL_PUB", "/pub"))   # shared with hoast-player (public)
STATS = DATA/"stats.json"; PUB = PUBDIR/"status.json"
CSV   = DATA/"viewers.csv"; STATE = DATA/"alert_state.json"


def sh(cmd, t=12):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=t).stdout
    except Exception:
        return ""

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

def stream_state():
    x = sh(f"curl -s --max-time 5 {EARSHOT}")
    publishing = "<publishing/>" in x
    m = re.search(r"<nclients>(\d+)</nclients>", x)
    nclients = int(m.group(1)) if m else 0
    seg_age = None
    try:
        segs = list(DASH.glob("chunk-stream*.webm"))
        if segs:
            seg_age = round(time.time() - max(p.stat().st_mtime for p in segs))
    except Exception:
        pass
    live = publishing and seg_age is not None and seg_age < SEG_STALE_S
    return {"publishing": publishing, "nclients": nclients, "segment_age_s": seg_age, "live": live}

def encoder(ps, publishing):
    if not publishing:
        return {"speed": None, "behind": False}
    c = container_named(ps, "earshot")
    out = sh(f'docker exec {c} sh -c "grep -oE \\"speed=[ ]*[0-9.]+x\\" /tmp/nginx_rtmp_ffmpeg_log 2>/dev/null | tail -1"') if c else ""
    m = re.search(r"speed=\s*([0-9.]+)x", out)
    sp = float(m.group(1)) if m else None
    return {"speed": sp, "behind": sp is not None and sp < ENCODER_MIN}

def viewers(ps):
    c = container_named(ps, "hoast-player")
    out = sh(f"docker logs {c} --since {VIEWER_WINDOW}s 2>&1") if c else ""
    ips, countries = set(), {}
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
        if addr.is_private or addr.is_loopback or addr.is_link_local:
            continue
        if ip not in ips:
            ips.add(ip)
            if cc and cc not in ("--", "-", "XX"):
                countries[cc] = countries.get(cc, 0) + 1
    top = dict(sorted(countries.items(), key=lambda kv: -kv[1])[:6])
    return {"now": len(ips), "window_s": VIEWER_WINDOW, "countries": top}

def resolution_bitrate():
    r = re.search(r"scale=(\d+):(\d+)", FFMPEG)
    b = re.search(r"-b:v\s+(\S+)", FFMPEG)
    return (f"{r.group(1)}x{r.group(2)}" if r else None), (b.group(1) if b else None)


def telegram(msg):
    if not BOT or not CHAT:
        return
    data = urllib.parse.urlencode({"chat_id": CHAT, "text": msg}).encode()
    try:
        urllib.request.urlopen(f"https://api.telegram.org/bot{BOT}/sendMessage", data=data, timeout=10)
    except Exception:
        pass

def evaluate_alerts(s):
    try:
        state = json.loads(STATE.read_text())
    except Exception:
        state = {}
    counts, fired = state.get("_counts", {}), state.get("_fired", {})
    active, msgs = [], []
    down = [f"{x['name']} ({x.get('health') or x.get('state') or 'down'})"
            for x in s["services"] if not x["healthy"]]
    d, t = s["system"]["disk_used_pct"], s["system"]["temp_c"]
    st = s["stream"]
    stalled = bool(st["publishing"] and st["segment_age_s"] is not None and st["segment_age_s"] > SEG_STALE_S)
    conds = {
        "services_down":  (bool(down), "service(s) unhealthy: " + ", ".join(down), "all services healthy again"),
        "disk_full":      (d is not None and d >= DISK_FULL_PCT, f"disk {d}% full", "disk usage back to normal"),
        "overheat":       (t is not None and t >= TEMP_CRIT_C, f"CPU {t}°C, nearing 105°C critical", "CPU temp back below 100°C"),
        "encoder_behind": (s["encoder"]["behind"], f"encoder behind realtime ({s['encoder']['speed']}x)", "encoder keeping up again"),
        "stream_stalled": (stalled, f"stream publishing but segments {st['segment_age_s']}s stale", "stream flowing again"),
    }
    for key, (cond, problem, recovered) in conds.items():
        counts[key] = (counts.get(key, 0) + 1) if cond else 0
        if cond and counts[key] >= DEBOUNCE and not fired.get(key):
            msgs.append("🔴 " + problem); fired[key] = True
        elif not cond and fired.get(key):
            msgs.append("✅ " + recovered); fired[key] = False
        if fired.get(key):
            active.append(key)
    state["_counts"], state["_fired"] = counts, fired
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
                out.append({"t": p[0], "v": int(p[1]),
                            "temp": (float(p[2]) if p[2] not in ("", "None") else None)})
    except Exception:
        pass
    return out

def collect_once():
    ps = docker_ps()
    svcs = services(ps)
    strm = stream_state()
    res, br = resolution_bitrate()
    s = {
        "ts": now_iso(), "host": HOST, "services": svcs,
        "all_healthy": all(x["healthy"] for x in svcs) if svcs else False,
        "stream": strm, "encoder": encoder(ps, strm["publishing"]),
        "viewers": viewers(ps), "resolution": res, "bitrate": br,
        "system": {"temp_c": temp_c(), "load1": load1(), "mem_used_pct": None,
                   "disk_used_pct": disk_pct(), "uptime_s": uptime_s(), "cores": None},
    }
    s["alerts_active"] = evaluate_alerts(s)
    cc = ";".join(f"{k}:{v}" for k, v in s["viewers"].get("countries", {}).items())
    with open(CSV, "a") as f:
        f.write(f"{s['ts']},{s['viewers']['now']},{s['system']['temp_c']},{1 if strm['live'] else 0},{cc}\n")
    s["history"] = history()
    tmp = STATS.with_suffix(".json.tmp"); tmp.write_text(json.dumps(s, indent=1)); tmp.replace(STATS)
    pub = {"ts": s["ts"], "live": strm["live"], "publishing": strm["publishing"],
           "resolution": res, "bitrate": br, "viewers": s["viewers"]["now"],
           "countries": s["viewers"].get("countries", {}), "uptime_s": s["system"]["uptime_s"]}
    PUB.write_text(json.dumps(pub))   # in-place: stable inode for the hoast-player bind mount


def serve():
    DATA.mkdir(parents=True, exist_ok=True)
    class H(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k): super().__init__(*a, directory=str(DATA), **k)
        def log_message(self, *a): pass
    with socketserver.ThreadingTCPServer(("", PORT), H) as srv:
        srv.serve_forever()

def main():
    DATA.mkdir(parents=True, exist_ok=True)
    # dashboard.html is baked into the image at /app/web/index.html; expose it in DATA
    src = Path("/app/web/index.html")
    if src.exists():
        (DATA/"index.html").write_text(src.read_text())
    threading.Thread(target=serve, daemon=True).start()
    while True:
        try:
            collect_once()
        except Exception as e:
            print("collect error:", e, flush=True)
        time.sleep(INTERVAL)

if __name__ == "__main__":
    main()
